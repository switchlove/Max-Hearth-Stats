local rng = _radiant.math.get_default_rng()
local IntegerGaussianRandom = require 'lib.math.integer_gaussian_random'
local gaussian_rng = IntegerGaussianRandom(rng)
local constants = require 'constants'

local PopulationFaction = class()

local ALL_WORK_ORDERS = {
   'haul',
   'build',
   'mine',
   'job',
}

local THREAT_ESCAPED_TIMER = 10000

local VERSIONS = {
   ZERO = 0,
   MILITIA = 1,
   NUMBER_MAP_THREAT_STUFF = 2,
   PARTY_BANNER = 3,
   HEARTHLING_HAT_PALETTE_UPGRADE = 4,
   INVALID_CITY_TIER = 5,
   LUA_UNIT_INFO = 6
}
local NUM_PARTIES = 4
local MAX_CITY_TIER = 3

function PopulationFaction:get_version()
   return VERSIONS.LUA_UNIT_INFO
end

function PopulationFaction:initialize()
   self._log = radiant.log.create_logger('population')
   self._global_vision = {}

   -- Each hearthling's first trait assigned is unique from all other hearthling's first
   -- assigned trait (thus ensuring that we never end up with two 'herbivore-only'
   -- hearthlings, and the like.)
   self._prime_traits = {}
   self._roster_initialized = false

   self._sv.kingdom = nil
   self._sv.player_id = nil
   self._sv.citizens = nil
   self._sv._generated_citizens = nil
   self._sv.parties = {}
   self._sv.party_member_counts = nil
   self._sv.bulletins = {}
   self._sv.is_npc = true
   self._sv.threat_level = 0
   self._sv.threat_data = nil
   self._sv.inventory_state = nil
   self._sv.city_tier = 1
   self._sv.player_acknowledges_tier_2 = false
   self._sv.player_acknowledges_tier_3 = false
   self._sv.camp_placed = false
   self._sv.suspended_work_orders = {}

   self._sv._max_citizens_ever = 0
   self._sv._game_options = {}
end

function PopulationFaction:reset_generated_citizens()
   if self._sv._generated_citizens then
      -- destroy existing roster (can exist if we went to the select roster screen and then restarted the game flow by pressing f5)
      for _, citizen_entry in pairs(self._sv._generated_citizens) do
         for _, citizen in pairs(citizen_entry) do
               radiant.entities.destroy_entity(citizen)
         end
      end
   end

   self._sv._generated_citizens = {}
end

function PopulationFaction:set_generated_citizen(i, citizen_entry)
   self._sv._generated_citizens[i] = citizen_entry
end

function PopulationFaction:get_generated_citizen(i)
   return self._sv._generated_citizens[i]
end

function PopulationFaction:get_generated_citizens()
   return self._sv._generated_citizens
end

function PopulationFaction:unset_generated_citizens()
   self._sv._generated_citizens = nil
end

function PopulationFaction:get_roster_initialized()
   return self._roster_initialized
end

function PopulationFaction:set_roster_initialized(value)
   self._roster_initialized = value
end

function PopulationFaction:place_camp()
   local result = self._sv.camp_placed
   self._sv.camp_placed = true
   return result
end

function PopulationFaction:is_camp_placed()
   return self._sv.camp_placed
end

function PopulationFaction:create(player_id, kingdom, is_npc)
   self._sv.kingdom = kingdom
   self._sv.player_id = player_id
   self._sv.citizens = _radiant.sim.alloc_number_map()
   self._sv._generated_citizens = {}
   self._sv.threat_data = radiant.create_datastore({threat_level = 0, in_combat = false})
   self._sv.is_npc = is_npc
   if not self._sv.is_npc then
      self:_create_default_parties()
   end
end

function PopulationFaction:restore()
   if not self._sv.is_npc then
      self:_create_default_parties() -- ensure default parties on load T_T sigh
   end
   self._sv.citizens:remove_nil_values()
   --Check what the music should be
   self:_update_threat_level()
end

function PopulationFaction:activate()
   self._sensor_traces = {}
   self._entity_hostility = {}
   self._data = {}

   if self._sv.kingdom then
      self._data = radiant.resources.load_json(self._sv.kingdom)
      self:_on_citizen_count_changed()
   end

   self:_load_traits()

   radiant.events.listen_once(radiant, 'radiant:game_loaded', function(e)
         for id, citizen in self._sv.citizens:each() do
            self:_monitor_citizen(citizen)
         end
      end)

   --Listen on amenity changes
   radiant.events.listen(self, 'stonehearth:amenity_changed', self, self._on_amenity_changed)

   -- Listen for when any population's entity has been destroyed, so we can remove it from our global vision.
   -- XXX: Temporary fix for combat music not stopping when all nearby monsters have been destroyed. Sometimes, citizen sensors
   -- do not remove entities that are out of range and as a result the entity is still included in the threat level.
   radiant.events.listen(stonehearth.population, "stonehearth:population:entity_destroyed", self, function(self, e)
         local entity_id = e.entity_id
         if self._global_vision[entity_id] then
            self:_on_global_vision_entity_destroyed(entity_id)
         end
      end)

   if not self._sv.is_npc then
      self._sv.party_member_counts = {}
      self._party_listeners = {}
      for party_name, party in pairs(self._sv.parties) do
         local party_component = party:get_component('stonehearth:party')
         self._sv.party_member_counts[party_name] = party_component and party_component:get_party_size() or 0
         self._party_listeners[party_name] = radiant.events.listen(party, 'stonehearth:party:size_changed', self, function(self, e)
               self._sv.party_member_counts[party_name] = e.size
               self.__saved_variables:mark_changed()
            end)
      end
   end

   self:_create_combat_listener()
end

function PopulationFaction:post_activate()
   local town = stonehearth.town:get_town(self._sv.player_id)
   for work_order, is_suspended in pairs(self._sv.suspended_work_orders) do
      if is_suspended then
         radiant.events.trigger_async(stonehearth, 'stonehearth:population:faction_work_order_changed', {work_order_name = work_order, is_suspended = is_suspended, player_id = self._sv.player_id})
      end
   end

   if self._remove_unit_infos then
      for id, citizen in self._sv.citizens:each() do
         local unit_info = citizen:get_component('unit_info') --cpp unit info
         local unit_info_component = citizen:get_component('stonehearth:unit_info')
         if unit_info then
            radiant.entities.set_display_name(citizen, unit_info:get_display_name())
            local custom_name = unit_info:get_custom_name()
            radiant.entities.set_custom_name(citizen, custom_name)
            if not unit_info_component or unit_info_component:get_description() == nil then -- this is for compatibility with the remove_level_0 update in the job_component
               radiant.entities.set_description(citizen, unit_info:get_description())
            end
            citizen:set_debug_text(custom_name)
            citizen:remove_component('unit_info')
         end
      end

      for party_name, party in pairs(self._sv.parties) do
         radiant.entities.set_icon(party, '/stonehearth/services/server/population/data/images/'..party_name..'_banner.png')
         radiant.entities.set_display_name(party, 'i18n(stonehearth:data.prototypes.party.display_names.'..party_name..')')
         party:get_component('stonehearth:party'):set_banner_variant(party_name)
         party:remove_component('unit_info')
      end

      self._remove_unit_infos = nil
   end
end

function PopulationFaction:_load_traits()
   self._traits = radiant.resources.load_json('stonehearth:traits_index')
   self._flat_trait_index = {}

   for group_name, group in pairs(self._traits.groups) do
      self._flat_trait_index[group_name] = group
   end

   for trait_name, trait in pairs(self._traits.traits) do
      self._flat_trait_index[trait_name] = trait
   end
end

-- Picks a trait at (uniformly) random from the list of available traits; if the
-- picked trait is incompatible with the list of current traits, that trait is
-- removed from the supplied list of available traits.  Otherwise, the set of available
-- traits is not affected; it is up to the caller to remove the successfully-returned
-- trait.
function PopulationFaction:_pick_random_trait(citizen, current_traits, available_traits, options)
   local function valid_trait(trait_uri, trait)
      for current_trait_uri, current_trait in pairs(current_traits) do
         -- Check for excluded traits.
         if current_trait.excludes and current_trait.excludes[trait_uri] then
            return false
         end
         if trait.excludes and trait.excludes[current_trait_uri] then
            return false
         end
         -- TODO(?) check for excluded groups?  Tags?
      end

      if trait.immigration_only and options.embarking then
         return false
      end
      if trait.gender and trait.gender ~= self:get_gender(citizen) then
         return false
      end

      return true
   end

   local n = radiant.size(available_traits)
   while n > 0 do
      local trait_uri = radiant.get_random_map_key(available_traits, rng)
      local group_name = nil

      if self._traits.groups[trait_uri] then
         group_name = trait_uri

         local group = available_traits[group_name]

         trait_uri = radiant.get_random_map_key(group, rng)

         if valid_trait(trait_uri, group[trait_uri]) then
            return trait_uri, group_name
         end
      else
         if valid_trait(trait_uri, available_traits[trait_uri]) then
            return trait_uri, nil
         end
      end

      -- No dice--the trait is in conflict.
      local group = nil
      if group_name then
         group = available_traits[group_name]
         group[trait_uri] = nil

         -- We cleaned up the group; now, overwrite trait_uri to possibly
         -- clean up the group's entry.
         trait_uri = group_name
      end

      if not group_name or not next(group) then
         available_traits[trait_uri] = nil
         -- We removed a top-level entry from the list of available traits,
         -- so, decrement the total we can look through.
         n = n - 1
      end
   end

   return nil, nil
end

function PopulationFaction:regenerate_stats(citizen, options)
   assert(options)
   local role_data = self:get_role_data()

   self:_allocate_attribute_points(citizen, role_data, options.embarking)

   local tc = citizen:get_component('stonehearth:traits')
   if tc then
      self._prime_traits = {}
      local smc = citizen:get_component('stonehearth:subject_matter')
      if smc then
         smc:reset()
      end
      tc:clear_all_traits()
      self:_assign_citizen_traits(citizen, options)
   end
   
   self:_assign_citizen_item_preferences(citizen, options)
end

--Set the city tier
function PopulationFaction:set_city_tier(city_tier)
   if city_tier <= MAX_CITY_TIER and city_tier >= 1 then
      self._sv.city_tier = city_tier
      -- add thought for each citizen when city tier increases
      for id, citizen in self._sv.citizens:each() do
         if citizen:is_valid() then
            radiant.entities.add_thought(citizen, 'stonehearth:thoughts:town:township:level_' .. city_tier)
         end
      end

      radiant.events.trigger_async(self,
         "stonehearth:population:township_changed",
         { city_tier = city_tier })

      self.__saved_variables:mark_changed()
   end
end

function PopulationFaction:player_acknowledges_tier()
   if self._sv.city_tier == 2 then
      self._sv.player_acknowledges_tier_2 = true
   elseif self._sv.city_tier == 3 then
      self._sv.player_acknowledges_tier_3 = true
   end
   self.__saved_variables:mark_changed()
end

--Get the city tier
function PopulationFaction:get_city_tier()
   return self._sv.city_tier
end

function PopulationFaction:get_datastore(reason)
   return self.__saved_variables
end

function PopulationFaction:set_kingdom(kingdom)
   if not self._sv.kingdom then
      self._sv.kingdom = kingdom
      self._data = radiant.resources.load_json(self._sv.kingdom)
      self:_create_town_name()
      self:_on_citizen_count_changed()
      self.__saved_variables:mark_changed()
   end
end

function PopulationFaction:debug_set_kingdom(kingdom)
   self._sv.kingdom = kingdom
   self._data = radiant.resources.load_json(self._sv.kingdom)
   self.__saved_variables:mark_changed()
end

function PopulationFaction:get_kingdom()
   return self._sv.kingdom
end

function PopulationFaction:get_banner_style()
   return self._data.camp_standard, self._data.camp_standard_ghost
end

function PopulationFaction:get_starting_resource()
   return self._data.starting_resource
end

function PopulationFaction:get_amenity_to_other_players()
   return self._data.amenity_to
end

function PopulationFaction:get_pet_names()
   return self._data.pet_names
end

function PopulationFaction:get_town_task_group_uris()
   local task_groups_list_uri
   if self._data and self._sv.kingdom then
      task_groups_list_uri = self._data.task_groups
   else
      -- TODO:X: This is super hacky to catch 2 edge cases:
      --         - the town is created before the player is assigned a kingdom
      --         - the town is initialized before the faction is (when loading a savegame)
      task_groups_list_uri = 'stonehearth:data:player_task_groups'
   end
   
   if task_groups_list_uri then
      return radiant.resources.load_json(task_groups_list_uri).task_groups
   else
      return {}
   end
end

function PopulationFaction:get_job_index()
   local job_index = 'stonehearth:jobs:index'
   if self:is_npc() then
      job_index = 'stonehearth:jobs:npc_job_index'
   end
   if self._data.job_index then
      job_index = self._data.job_index
   end
   return job_index
end

function PopulationFaction:get_amenity_to_strangers()
   return self._data.amenity_to_strangers or 'neutral'
end

function PopulationFaction:get_player_id()
   return self._sv.player_id
end

function PopulationFaction:get_citizen_count()
   return self._sv.citizens:get_size()
end

function PopulationFaction:is_citizen(entity)
   if not entity or not entity:is_valid() then
      return false
   end
   return self._sv.citizens:contains(entity:get_id())
end

function PopulationFaction:get_party_by_name(name)
   return self._sv.parties[name]
end

function PopulationFaction:is_npc()
   return self._sv.is_npc
end

function PopulationFaction:generate_town_name()
   return self.generate_town_name_from_pieces(self._data.town_pieces)
end

function PopulationFaction.generate_town_name_from_pieces(town_pieces)
   local composite_name = 'Defaultville'

   --If we do not yet have the town data, then return a default town name
   if town_pieces then
      local prefixes = town_pieces.optional_prefix
      local base_names = town_pieces.town_name
      local suffix = town_pieces.suffix

      --make a composite
      local target_prefix = prefixes[rng:get_int(1, #prefixes)]
      local target_base = base_names[rng:get_int(1, #base_names)]
      local target_suffix = suffix[rng:get_int(1, #suffix)]

      if target_base then
         composite_name = target_base
      end

      if target_prefix and rng:get_int(1, 100) < 40 then
         composite_name = target_prefix .. ' ' .. composite_name
      end

      if target_suffix and rng:get_int(1, 100) < 80 then
         composite_name = composite_name .. target_suffix
      end
   end

   return composite_name
end

function PopulationFaction:_create_town_name()
   --Set the town name for the town
   local town =  stonehearth.town:get_town(self._sv.player_id)
   town:set_town_name(self:generate_town_name())
end

function PopulationFaction:create_new_citizen_traitless(role, gender)
   return self:create_new_citizen(role, gender, {suppress_traits = true})
end

function PopulationFaction:create_new_citizen(role, gender, options)
   options = options or {}
   if not gender then
      gender = self:_pick_random_gender()
   end

   local citizen = self:generate_citizen_from_role(role, gender)

   self:_set_citizen_initial_state(citizen, gender, role, options)
   self._sv.citizens:add(citizen:get_id(), citizen)
   self:_on_citizen_count_changed()
   self:_monitor_citizen(citizen)

   --Add thoughts for new citizens.  Non-player citizens will still get this call, but if they don't have a happiness component it will be discarded.
   --Note that this may need to be revisited if we ever create alternative means for adding citizens to the town. -rhough
   radiant.entities.add_thought(citizen, 'stonehearth:thoughts:town:founding:pioneering_spirit')
   self.__saved_variables:mark_changed()

   return citizen
end

function PopulationFaction:generate_citizen_from_role(role, gender)
   local role_data = self:get_role_data(role)
   if not role_data then
      error(string.format('unknown role %s in population %s', role, self._sv.player_id))
   end

   --If there is no gender, default to male
   if not role_data[gender] then
      gender = constants.population.DEFAULT_GENDER
   end
   local entities = role_data[gender].uri
   if not entities then
      error(string.format('role %s in population has no gender table for %s', role, gender))
   end

   local uri = entities[rng:get_int(1, #entities)]
   return self:create_entity(uri)
end

-- create an entity and make it belong to our faction
function PopulationFaction:create_entity(uri, options)
   return radiant.entities.create_entity(uri, { owner = self._sv.player_id })
end

function PopulationFaction:generate_starting_citizen(options)
   local options = options or {}
   local citizen = self:create_new_citizen(nil, options.gender, options)
   local job = options.job or 'stonehearth:jobs:worker'
   citizen:add_component('stonehearth:job')
               :promote_to(job, {
                  talisman = options.talisman
               })
   return citizen
end

function PopulationFaction:remove_citizen(citizen)
   self._sv.citizens:remove(citizen:get_id())
   radiant.entities.set_player_id(citizen, '')
   self:_on_citizen_count_changed()
end

function PopulationFaction:get_role_data(role)
   if not role then
      role = 'default'
   end
   local roles = self._data.roles
   return roles[role]
end

function PopulationFaction:get_gender(citizen)
   if radiant.entities.exists(citizen) then
      local render_info = citizen:get_component('render_info')
      -- currently the only way gender is stored is as a model variant on the entity
      local model_variant = render_info and render_info:get_model_variant()
      -- check if the model variant (ex. 'female') exists in the genders enum
      -- otherwise return the default gender
      local gender = constants.population.genders[model_variant] or
                     constants.population.DEFAULT_GENDER
      return gender
   end
end

-- get entity uris for this gender and role (optional)
function PopulationFaction:get_gender_uris(gender, role)
   local role_data = self:get_role_data(role)
   local gender_data = role_data and role_data[gender]
   local uris = gender_data and gender_data.uri
   return uris
end

function PopulationFaction:copy_citizen_stats(citizen, new_citizen)
   -- copy over traits
   local tc = citizen:get_component('stonehearth:traits')
   local traits = tc and tc:get_traits()
   if traits then
      local new_citizen_traits = new_citizen:get_component('stonehearth:traits')
      if new_citizen_traits then
         new_citizen_traits:clear_all_traits()
         for trait, _ in pairs(traits) do
            new_citizen_traits:add_trait(trait)
         end
      end
   end

   -- copy over attributes
   local role_data = self:get_role_data('default')
   local attr_distr = role_data.attribute_distribution
   if attr_distr then
      local ac = citizen:get_component('stonehearth:attributes')
      if ac then
         local new_citizen_attributes = new_citizen:get_component('stonehearth:attributes')
         if new_citizen_attributes then
            for name, _ in pairs(attr_distr.point_limits) do
               local value = ac:get_attribute(name)
               new_citizen_attributes:set_attribute(name, value)
            end
         end
      end
   end
end

function PopulationFaction:_pick_random_gender()
   if rng:get_int(1, 2) == 1 then
      return constants.population.genders.male
   else
      return constants.population.genders.female
   end
end

function PopulationFaction:generate_roster(count, options)
   local roster = {}
   self._prime_traits = {}

   for i = 1, count do
      local citizen = self:generate_starting_citizen(options)
      roster[i] = citizen
   end

   return roster
end

function PopulationFaction:get_game_options()
   return self._sv._game_options
end

function PopulationFaction:set_game_options(options)
   if options.game_mode then
      -- TODO: only hosting player should have a game mode in their options
      stonehearth.game_creation:set_game_mode(options.game_mode)
   end

   self._sv._game_options = options

   if not self._sv._game_options.starting_items then
      self._sv._game_options.starting_items = {}
      self._sv._game_options.starting_items["stonehearth:carpenter:talisman"] = 1
      self._sv._game_options.starting_items["stonehearth:trapper:talisman"] = 1
   end

   if not self._sv._game_options.starting_gold then
      self._sv._game_options.starting_gold = 2
   end
end

--When the amenity changes for this population, citizens should
--check the threat level of everyone already in their sight sensors
function PopulationFaction:_on_amenity_changed(e)
   self._global_vision = {}
   for _, trace in pairs(self._sensor_traces) do
      trace:push_object_state()
   end
   self._entity_hostility = {}
   self:_update_threat_level()
end

function PopulationFaction:_monitor_citizen(citizen)
   if not citizen:is_valid() then
      self._log:error('_monitor_citizen cannot monitor invalid citizen %s', citizen)
      return
   end

   local citizen_id = citizen:get_id()

   -- listen for entity destroy bulletins so we'll know when the pass away
   radiant.events.listen_once(citizen,
      'radiant:entity:pre_destroy', self,
      self._on_entity_destroyed)

   radiant.events.listen_once(citizen,
      'stonehearth:kill_event', self,
      self._on_entity_killed)

   -- Don't trace npc sight sensors. We only need that for combat music which only cares about non-npc players
   if stonehearth.player:is_player_npc(self._sv.player_id) then
      return
   end

   -- subscribe to their sensor so we can look for trouble.
   local sensor_list = citizen:get_component('sensor_list')
   if sensor_list then
      local sensor = sensor_list:get_sensor('sight')
      if sensor then
         self._sensor_traces[citizen_id] = sensor:trace_contents('monitoring threat level')
                                                      :on_added(function(visitor_id, visitor)
                                                            self:_on_seen_by(citizen_id, visitor_id, visitor)
                                                         end)
                                                      :on_removed(function(visitor_id)
                                                            self:_on_unseen_by(citizen_id, visitor_id)
                                                         end)
                                                      :push_object_state()
      end
   end
end

function PopulationFaction:_on_combat_started(evt)
   local threat_d = self._sv.threat_data:get_data()
   if threat_d.in_combat or self._sv.is_npc then
      return
   end
   if self._sv.player_id ~= radiant.entities.get_player_id(evt.entity) then
      -- don't need to listen unless we're out of combat
      if self._combat_listener then
         self._combat_listener:destroy()
         self._combat_listener = nil
      end
      self._sv.threat_data:set_data({
            threat_level = threat_d.threat_level,
            in_combat = true
         })
   end
end

function PopulationFaction:_get_threat_level(visitor, visitor_id)
   local is_hostile
   if self._entity_hostility and self._entity_hostility[visitor_id] ~= nil then
      is_hostile = self._entity_hostility[visitor_id]
   else
      local visitor_player_id = radiant.entities.get_player_id(visitor)
      is_hostile = stonehearth.player:are_player_ids_hostile(self._sv.player_id, visitor_player_id)
      self._entity_hostility[visitor_id] = is_hostile
   end
   if is_hostile then
      return radiant.entities.get_attribute(visitor, 'menace', 0)
   end
   return 0
end

function PopulationFaction:_on_seen_by(spotter_id, visitor_id, visitor)
   if not visitor or not visitor:is_valid() then
      -- visitor is already destroyed
      return
   end

   local threat_level = self:_get_threat_level(visitor, visitor_id)
   if threat_level <= 0 then
      -- not interesting.  move along!
      return
   end

   local entry = self._global_vision[visitor_id]
   if not entry then
      entry = {
         seen_by = { [spotter_id] = true },
         threat_level = threat_level,
         entity = visitor,
      }
      self._global_vision[visitor_id] = entry

      self:_update_threat_level()

      radiant.events.trigger_async(self, 'stonehearth:population:new_threat', {
            entity_id = visitor_id,
            entity = visitor,
         });
   end
   entry.seen_by[spotter_id] = true
end

function PopulationFaction:_on_unseen_by(spotter_id, visitor_id)
   local entry = self._global_vision[visitor_id]
   if entry then
      entry.seen_by[spotter_id] = nil
      self._log:debug("visitor %d still seen by %d citizens", visitor_id, radiant.size(entry.seen_by))
      if radiant.empty(entry.seen_by) then
         self._global_vision[visitor_id] = nil

         --If the threat is dead, update immediately
         local visitor = radiant.entities.get_entity(visitor_id)

         if visitor and visitor:is_valid() then
            --If the threat goes down because you've just unseen someone
            --as opposed to b/c they died, wait to update the threat level until
            --a few seconds (10?) have gone by. Makes sense--how do you know you've escaped--
            --and also so that we don't switch back to non-combat modes when there's a high
            --chance of getting back into combat.
            radiant.set_realtime_timer("waiting for unseen threat update", THREAT_ESCAPED_TIMER, function()
                  self:_update_threat_level()
               end)
         else
            self:_update_threat_level()
         end

      end
   end
end

--Will show a simple notification that zooms to a citizen when clicked.
--will expire if the citizen isn't around anymore
function PopulationFaction:show_notification_for_citizen(citizen, title, options)
   local citizen_id = citizen:get_id()
   if not self._sv.bulletins[citizen_id] then
      self._sv.bulletins[citizen_id] = {}
   elseif self._sv.bulletins[citizen_id][title] then
      if options.ignore_on_repeat_add then
         return
      end
      --If a bulletin already exists for this citizen with this title, remove it to replace with the new one
      local bulletin_id = self._sv.bulletins[citizen_id][title]:get_id()
      stonehearth.bulletin_board:remove_bulletin(bulletin_id)
   end

   local town_name = stonehearth.town:get_town(self._sv.player_id):get_town_name()
   local notification_type = options and options.type or 'info'
   local message = options and options.message or ''

   self._sv.bulletins[citizen_id][title] = stonehearth.bulletin_board:post_bulletin(self._sv.player_id)
            :set_callback_instance(self)
            :set_type(notification_type)
            :set_data({
               title = title,
               message = message,
               zoom_to_entity = citizen,
            })
            :add_i18n_data('citizen_custom_name', radiant.entities.get_custom_name(citizen))
            :add_i18n_data('citizen_display_name', radiant.entities.get_display_name(citizen))
            :add_i18n_data('town_name', town_name)

   self.__saved_variables:mark_changed()
end

function PopulationFaction:destroy_notification_for_citizen(citizen, title)
   local citizen_id = citizen:get_id()
   local bulletins = self._sv.bulletins[citizen_id]
   if bulletins and bulletins[title] then
      local bulletin = bulletins[title]
      stonehearth.bulletin_board:remove_bulletin(bulletin)
      bulletins[title] = nil
      self.__saved_variables:mark_changed()
   end
end

function PopulationFaction:get_citizens()
   return self._sv.citizens
end

function PopulationFaction:_on_entity_destroyed(evt)
   local entity_id = evt.entity_id

   -- update the score
   if self._sv.citizens:contains(entity_id) then
      self:_on_citizen_destroyed(entity_id)
   end

   -- let other populations know that we've been destroyed
   -- so they can remove us from their global vision
   radiant.events.trigger_async(stonehearth.population,
      "stonehearth:population:entity_destroyed",
      { entity_id = entity_id })

   if self._global_vision[entity_id] then
      self:_on_global_vision_entity_destroyed(evt.entity_id)
   end
end

function PopulationFaction:_on_entity_killed(args)
   radiant.events.trigger_async(self,
      "stonehearth:population:citizen_killed")
end

function PopulationFaction:_on_citizen_destroyed(entity_id)
   self._sv.citizens:remove(entity_id)

   -- remove associated bulletins
   local bulletins = self._sv.bulletins[entity_id]
   if bulletins then
      self._sv.bulletins[entity_id] = nil
      for title, bulletin in pairs(bulletins) do
         local bulletin_id = bulletin:get_id()
         stonehearth.bulletin_board:remove_bulletin(bulletin_id)
      end
   end

   -- nuke sensors
   local sensor_trace = self._sensor_traces[entity_id]
   if sensor_trace then
      self._sensor_traces[entity_id] = nil
      sensor_trace:destroy()
   end

   -- global vision
   for visitor_id, _ in pairs(self._global_vision) do
      self:_on_unseen_by(entity_id, visitor_id)
   end

   self:_on_citizen_count_changed()

   self.__saved_variables:mark_changed()
   return radiant.events.UNLISTEN
end

function PopulationFaction:_on_global_vision_entity_destroyed(entity_id)
   self._global_vision[entity_id] = nil
   self:_update_threat_level()
end

function PopulationFaction:_update_threat_level()
   local threat_level = 0
   for _, entry in pairs(self._global_vision) do
      threat_level = threat_level + entry.threat_level
   end

   local threat_d = self._sv.threat_data:get_data()
   local in_combat = threat_d.in_combat or false

   -- if total threat level is 0 then we are not longer in combat
   if threat_level <= 0 then
      self:_create_combat_listener()
      in_combat = false
   end

   -- update the threat level
   self._sv.threat_data:set_data({
      threat_level = threat_level,
      in_combat = in_combat
   })
end

function PopulationFaction:_set_citizen_initial_state(citizen, gender, role, options)
   local role_data = self:get_role_data(role)

   -- name
   self:set_citizen_name(citizen, gender, role_data)
   -- customize their appearance
   local cc = citizen:get_component('stonehearth:customization')
   if cc then
      cc:generate_custom_appearance()
   end
   -- personality
   self:_set_personality(citizen)
   -- attribute points
   self:_allocate_attribute_points(citizen, role_data, { embarking = true })
   -- give them traits
   self:_assign_citizen_traits(citizen, options)
   -- give them item preferences
   self:_assign_citizen_item_preferences(citizen, options)
end

function PopulationFaction:set_citizen_name(citizen, gender, role_data)
   role_data = role_data or self:get_role_data()
   local name = self:generate_random_name(gender, role_data)
   if name then
      radiant.entities.set_custom_name(citizen, name)
      citizen:set_debug_text(name)
   end
end

function PopulationFaction:_set_personality(citizen)
   --TODO: parametrize these by role too?
   local personality = stonehearth.personality:get_new_personality()
   local personality_component = citizen:add_component('stonehearth:personality')
   personality_component:set_personality(personality)

   --For the teacher field, assign the one appropriate for this kingdom
   personality_component:add_substitution_by_parameter('teacher', self._sv.kingdom, 'stonehearth')
end

function PopulationFaction:_assign_citizen_item_preferences(citizen, options)
   if not options.suppress_item_preferences then
      local appeal = citizen:get_component('stonehearth:appeal')
      if appeal then
         appeal:generate_item_preferences()
      end
   end
end

function PopulationFaction:_assign_citizen_traits(citizen, options)
   local tc = citizen:get_component('stonehearth:traits')
   if options.suppress_traits or not tc then
      return
   end

   local num_traits = gaussian_rng:get_int(1, 2, 0.33)
   self._log:info('assigning %d traits', num_traits)

   local traits = {}
   local all_traits = radiant.deep_copy(self._flat_trait_index)
   local start = 1

   -- When doing embarkation trait assignment, make sure every hearthling
   -- gets a 'prime' trait (i.e. ensure we use at least K traits from the
   -- complete list of traits for K hearthlings).
   if options.embarking then
      local available_prime_traits = radiant.deep_copy(all_traits)

      -- Remove all the previously-assigned prime traits from our copy.
      for trait_uri, group_name in pairs(self._prime_traits) do
         if group_name and available_prime_traits[group_name] then
            available_prime_traits[group_name][trait_uri] = nil
            if not next(available_prime_traits[group_name]) then
               available_prime_traits[group_name] = nil
            end
         elseif available_prime_traits[trait_uri] then
            available_prime_traits[trait_uri] = nil
         end
      end

      local trait_uri, group_name = self:_pick_random_trait(citizen, traits, available_prime_traits, options)
      if not trait_uri then
         self._log:info('ran out of prime traits!')
         self._prime_traits = {}
         trait_uri, group_name = self:_pick_random_trait(citizen, traits, all_traits, options)
         assert(trait_uri)
      end
      self:_add_trait(traits, trait_uri, group_name, all_traits, tc)
      self._prime_traits[trait_uri] = group_name or false

      self._log:info('  prime trait %s', trait_uri)
      start = 2
   end

   for i = start, num_traits do
      local trait_uri, group_name = self:_pick_random_trait(citizen, traits, all_traits, options)
      if not trait_uri then
         self._log:info('ran out of traits!')
         break
      end

      self._log:info('  picked %s', trait_uri)
      self:_add_trait(traits, trait_uri, group_name, all_traits, tc)
   end
end

function PopulationFaction:_add_trait(traits, trait_uri, group_name, all_traits, trait_component)
   local trait_map = all_traits
   if group_name then
      trait_map = all_traits[group_name]
   end
   traits[trait_uri] = trait_map[trait_uri]

   if group_name then
      all_traits[group_name] = nil
   else
      all_traits[trait_uri] = nil
   end

   trait_component:add_trait(trait_uri)
end

function PopulationFaction:get_home_location()
   return self._town_location
end

function PopulationFaction:set_home_location(location)
   self._town_location = location
end

function PopulationFaction:generate_random_name(gender, role_data)
   if not role_data[gender] then
      gender = constants.population.DEFAULT_GENDER
   end

   if role_data[gender].given_names then
      local first_names = ""

      first_names = role_data[gender].given_names

      local name = first_names[rng:get_int(1, #first_names)]

      if role_data.surnames then
         local surname = role_data.surnames[rng:get_int(1, #role_data.surnames)]
         name = name .. ' ' .. surname
      end
      return name
   else
      return nil
   end
end

function PopulationFaction:_allocate_attribute_points(citizen, role_data, embarking)
   -- if we're embarking, allocate attributes from the role_data instead of
   -- assigning completely random attributes
   if not embarking then
      return
   end

   local attr_distr = role_data.attribute_distribution
   if attr_distr then
      local attributes_component = citizen:get_component('stonehearth:attributes')
      if attributes_component then
         local num_points_to_allocate = rng:get_int(attr_distr.allocated_points.min, attr_distr.allocated_points.max)
         local point_limits = attr_distr.point_limits
         local points = {}
         local attr_name_list = {}
         for name, data in pairs(point_limits) do
            table.insert(attr_name_list, name)
            points[name] = data.min
         end

         while num_points_to_allocate > 0 and #attr_name_list > 0 do
            local random_attr, random_index = radiant.get_random_value(attr_name_list)
            points[random_attr] = points[random_attr] + 1
            if points[random_attr] >= point_limits[random_attr].max then
               table.remove(attr_name_list, random_index)
            end
            num_points_to_allocate = num_points_to_allocate - 1
         end

         for name, value in pairs(points) do
            attributes_component:set_attribute(name, value)
         end
      end
   end
end

--- Given an entity, iterate through the array of people in this town and find the
--  person closest to the entity.
--  Returns the closest person and the entity's distance to that person.
function PopulationFaction:find_closest_townsperson_to(entity)
   local shortest_distance = nil
   local closest_person = nil
   for id, citizen in self._sv.citizens:each() do
      if citizen:is_valid() and entity:get_id() ~= id then
         local distance = radiant.entities.distance_between(entity, citizen)
         if not shortest_distance or distance < shortest_distance then
            shortest_distance = distance
            closest_person = citizen
         end
      end
   end
   return closest_person, shortest_distance
end

-- the entry point in the ui when someone clicks a check box to opt into or out of a job
-- we need to update our work_order map and notify the town
function PopulationFaction:change_work_order_command(session, response, work_order, citizen_id, checked)
   local citizen = self._sv.citizens:get(citizen_id)
   if citizen and citizen:is_valid() then
      if checked == true then
         citizen:add_component('stonehearth:work_order'):enable_work_order(work_order)
      elseif checked == false then
         citizen:add_component('stonehearth:work_order'):disable_work_order(work_order)
      end
   end

   return true
end

-- Called when user wants to toggle whether a work order is suspended
function PopulationFaction:set_work_order_suspend_command(session, response, work_order, is_suspended)
   local suspended = self._sv.suspended_work_orders[work_order]
   if suspended ~= is_suspended then
      self._sv.suspended_work_orders[work_order] = is_suspended
      radiant.events.trigger_async(stonehearth, 'stonehearth:population:faction_work_order_changed', {work_order_name = work_order, is_suspended = is_suspended, player_id = self._sv.player_id})
      self.__saved_variables:mark_changed()
   end

   return true
end

function PopulationFaction:is_work_order_suspended(work_order)
   return self._sv.suspended_work_orders[work_order]
end

function PopulationFaction:get_work_order_categories()
   return ALL_WORK_ORDERS
end

-- Process when the number of citizens has changed in the population
function PopulationFaction:_on_citizen_count_changed()
   if not self._sv.is_npc then
      -- only players have inventory limites
      local num_citizens = self._sv.citizens:get_size() or 0
      if num_citizens > self._sv._max_citizens_ever then
         self._sv._max_citizens_ever = num_citizens
         if self._data and self._data.inventory_capacity_equation then
            local equation = string.gsub(self._data.inventory_capacity_equation, 'num_citizens', num_citizens)
            local fn = loadstring('return ' .. equation)
            local new_capacity = fn() or 0
            local inventory = stonehearth.inventory:get_inventory(self._sv.player_id)
            if inventory then
               inventory:set_capacity(new_capacity)
            end
         end
         self.__saved_variables:mark_changed()
      end
   end
end

function PopulationFaction:_version_fixup_citizen_models()
   -- recursively reload the entity and all their attached equipment
   --
   local function reload_model_variants(entity)
      self._log:error('upgrading %s...', entity)
      local json = radiant.resources.load_json(entity:get_uri(), false, false) -- don't cache, don't warn if entity no longer exists
      if json and json.components.render_info then
         entity:add_component('render_info')
                     :load_from_json(json.components.render_info)
      end
      if json and json.components.model_variants then
         entity:add_component('model_variants')
                     :load_from_json(json.components.model_variants)
      end

      -- also, upgrade all attached equipment!
      local equipment = entity:get_component('stonehearth:equipment')
      if equipment then
         local all_items = equipment:get_all_items()
         self._log:error('%s has equipment (%d items).  upgrading it!', entity, radiant.size(all_items))
         for _, item in pairs(all_items) do
            reload_model_variants(item)
         end
      else
         self._log:error('%s has no equipment...', entity)
      end
   end

   for id, citizen in self._sv.citizens:each() do
      reload_model_variants(citizen)

      local cc = citizen:get_component('stonehearth:customization')
      if cc then
         cc:generate_custom_appearance()
      end
   end
end

function PopulationFaction:_create_combat_listener()
   if not self._sv.is_npc and not self._combat_listener then
      -- Listen on combat engagement, npc players do not need a listener
      self._combat_listener = radiant.events.listen(self,
         'stonehearth:population:engaged_in_combat',
         function(e)
            radiant.events.trigger_async(self, 'stonehearth:population:engaged_in_combat', e)
            self:_on_combat_started(e)
         end)
   end
end

function PopulationFaction:fixup_post_load(old_save_data)
   if old_save_data.version < VERSIONS.NUMBER_MAP_THREAT_STUFF then
      self._sv.citizens = _radiant.sim.alloc_number_map()

      for id, citizen in pairs(old_save_data.citizens) do
         self._sv.citizens:add(id, citizen)
      end

      self._sv.threat_data = radiant.create_datastore({threat_level = old_save_data.threat_level, in_combat = false})
      self._sv.threat_level = nil
      old_save_data._global_vision = nil
   end

   if old_save_data.version < VERSIONS.PARTY_BANNER then
      for party_name, party in pairs(self._sv.parties) do
         radiant.entities.set_icon(party, '/stonehearth/services/server/population/data/images/'..party_name..'_banner.png')
         party:get_component('stonehearth:party'):set_banner_variant(party_name)
      end
   end

   if old_save_data.version < VERSIONS.HEARTHLING_HAT_PALETTE_UPGRADE and self._sv.player_id == 'player_1' then
      -- the way we generate varity switched from the "use one of these models" mode to
      -- "use this random palette" path.  also, break the hair up into 2 sections to support
      -- hats.  just reload the hearthling's model variant and render info.

      -- we need to make sure we delay this until all the data for all the
      -- hearthlings and there equipment, etc.  has been loaded.
      radiant.events.listen_once(radiant, 'radiant:game_loaded', function()
            self._log:error('fixing up pre-hat save... hearthlings make look different')
            self:_version_fixup_citizen_models()
         end)
   end

   if old_save_data.version < VERSIONS.INVALID_CITY_TIER then
      if self._sv.city_tier > MAX_CITY_TIER then
         -- fix for save files where the max city tier became TOO LARGE
         self._sv.city_tier = MAX_CITY_TIER
         self._log:error("Fixing up city tier that had become too large.")
      end
   end

   if old_save_data.version < VERSIONS.LUA_UNIT_INFO then
      self._remove_unit_infos = true
   end
end

function PopulationFaction:set_inventory_state(state)
   self._sv.inventory_state = state
   self.__saved_variables:mark_changed()
end

function PopulationFaction:get_global_vision()
   return self._global_vision
end

function PopulationFaction:_create_default_parties()
   local player_id = self._sv.player_id
   for i=1, NUM_PARTIES do
      local party_name = 'party_' .. i
      if not self._sv.parties[party_name] then
         local party = stonehearth.unit_control:create_party_command({player_id = player_id}).party
         self._sv.parties[party_name] = party
         radiant.entities.set_icon(party, '/stonehearth/services/server/population/data/images/'..party_name..'_banner.png')
         radiant.entities.set_display_name(party, 'i18n(stonehearth:data.prototypes.party.display_names.'..party_name..')')
         party:get_component('stonehearth:party'):set_banner_variant(party_name)
      end
   end
end

return PopulationFaction
