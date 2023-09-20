--[[
        Copyright © 2023, Florent
        All rights reserved.

        Redistribution and use in source and binary forms, with or without
        modification, are permitted provided that the following conditions are met:

            * Redistributions of source code must retain the above copyright
              notice, this list of conditions and the following disclaimer.
            * Redistributions in binary form must reproduce the above copyright
              notice, this list of conditions and the following disclaimer in the
              documentation and/or other materials provided with the distribution.
            * Neither the name of Groundskeeper nor the
              names of its contributors may be used to endorse or promote products
              derived from this software without specific prior written permission.

        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
        ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
        WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
        DISCLAIMED. IN NO EVENT SHALL Florent BE LIABLE FOR ANY
        DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
        (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
        LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
        ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
        (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
        SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
]]
_addon.name = 'Groundskeeper'
_addon.version = '1.2.1'
_addon.author = 'Florent @ Phoenix'
_addon.commands = { 'groundskeeper', 'gk' }

require('luau')
require('tables')
require('strings')
require('sqlite3')
local config = require('config')
local texts = require('texts')
local packets = require('packets')

-- define the settings for the first use
local defaults = T{
	pos = {
		x = 500,
		y = 500
	},
	bg = {
		alpha = 100,
		red = 33,
		green = 33,
		blue = 33,
	},
	text = {
		alpha = 155,
		red = 227,
		green = 192,
		blue = 16,
		size = 12,
		font = 'Consolas'
	},
	flags = {
		right = false,
		bold = false,
		italic = false,
	},
	pad_text = true
}

local settings = config.load(defaults)
local received_tokens = T{}
local targets = T{}
local is_listening = false
local is_review = false

local max_length = 0
local zone, temp_zone, player_zone, progress_data, temp_tokens
local progress_text = texts.new(settings)

-- put everything into the start-up state
function initialize()
	is_listening = false
	is_review = false
	received_tokens = T{}
	targets = T{}
	zone = ''
	temp_zone = ''
	progress_data = ''
	temp_tokens = ''
	max_length = 0
	if progress_text then
		progress_text:visible(false)
	end
end

-- update the ui based on commands
function set_ui()
	if progress_text then
		progress_text:pos(settings.pos.x, settings.pos.y)
		progress_text:bg_color(settings.bg.red, settings.bg.green, settings.bg.blue)
		progress_text:bg_alpha(settings.bg.alpha)
		progress_text:color(settings.text.red, settings.text.green, settings.text.blue)
		progress_text:alpha(settings.text.alpha)
		progress_text:size(settings.text.size)
		progress_text:font(settings.text.font)
		progress_text:bold(settings.flags.bold)
		progress_text:italic(settings.flags.italic)
		create_text()
	end
end

-- whenever text arrives in the log
windower.register_event('incoming text', function(original, modified, original_mode, modified_mode, blocked)	
	-- on regime canceled
	if original:contains('Training regime canceled.') then
		-- clean up variables
		initialize()
		-- and hide, just in case
		hide()
	-- if we see this, we must not be have a current regime
	elseif original:contains('defeat the following:') then
		is_review = false
	-- upon first opening the tome/manual
	elseif original:contains('field operations fills its pages') then
		-- set up the necessary variables
		temp_tokens = ''
		is_listening = true
		is_review = true
	-- while reading a page
	elseif is_listening and original_mode == 151 then
		-- ignore the parts we don't need
		if original:contains('Training area: ') then
			-- only store the zone temporarily in case we are reviewing from a different zone
			temp_zone = original:split('Training area: ')[2]:sub(1, -1):split('.')[1]
		elseif original:contains('Target level range:') or original:contains('defeat the following:') then
			-- do nothing
			return
		-- on regime selected, assume we're done
		elseif original:contains('Set training regime to automatically repeat upon completion?') or original:contains('(End of list.)') then
			-- set the new zone as the temp_zone
			zone = temp_zone
			-- determine the targets
			parse_tokens(temp_tokens, is_review)
			-- reset variables
			is_listening = false
			is_review = false
		else
			-- set the temp_tokens once we're assigned the targets
			-- make them temporary in case we decide not to go with that page
			temp_tokens = original
		end
	end
	
	--TODO: Set a failsafe to ensure is_listening does not remain true if you leave the tome
end)

-- whenever data comes from the server
windower.register_event('incoming chunk', function(id, data)
	-- parse the packet data from Windower to find out if it's what we need	
	local packet = packets.parse('incoming', data)
	
	-- on a kill that gives experience
	if packet['Message'] == 8 and zone == player_zone then
		-- put the packet into a string
		local conpack = tostring(packet)
		-- use super fancy string manipulation to extract the enemy name from the packet
		local enemy = conpack:split('\n')[3]:split('(')[2]:split(')')[1]
		-- set up sql query to check the family of the monster
		local query = 'SELECT family FROM "monster" WHERE name = "' .. enemy .. '" LIMIT 1;'
		-- for each target
		for _, data in pairs(targets) do
			-- if the recorded target has the enemy's name in it
			if data.name and data.name:contains(enemy) then
				-- update the progress for killing that target
				update_count(data)
			-- if the recorded target does NOT have the enemy's name, but has a family
			elseif data.family then
				-- query the database for families using the dead enemy's name
				for family in db:urows(query) do
					-- lowercase it
					family = family:lower()
					-- if the target family matches the family in the database
					if data.family:contains(family) then
						-- update the progress for killing that target
						update_count(data)
					end
				end			
			end
		end
	-- on completing the regime
	elseif packet['Message'] == 643 then
		for _, data in pairs(targets) do
			-- reset all of the counts
			data.count = 0
		end
		-- refresh the text to account for the updated counts
		create_text()
	end
	
	-- on zone changing
	if id == 0x0B then
		-- hide the ui
		hide()
	end
	
	-- on zone changed
	if id == 0x0A then
		-- change the player's current zone
		player_zone = res.zones[windower.ffxi.get_info().zone].name
		-- show the ui
		show()
	end
end)

-- borrowed from InfoBar - set up the database connection. All this just to check for families.
windower.register_event('load', function()
	-- set up variable defaults
	initialize()
	-- set the player_zone with the zone the player is in
	player_zone = res.zones[windower.ffxi.get_info().zone].name
	-- open the database so we can query for families
    db = sqlite3.open(windower.addon_path..'/database.db')
end)

windower.register_event('unload', function()
	-- make sure the database is closed when the addon is unloaded
    db:close()
end)

-- when the user's status changes
windower.register_event('status change', function(new_status_id)
	-- on cutscene start
	if new_status_id == 4 then
		-- hide the addon so it isn't in the way
		hide()
	else
		-- show the addon once the cutscene is done
		show()
	end
end)

-- if job changes, regime is lost
windower.register_event('outgoing chunk', function(id)
	-- on job change
	if id == 0x100 then
		-- clear the UI, as the job change has nullified the regime
		initialize()
	end
end)

-- when the user logs in
windower.register_event('login', function()
	-- get things started
	initialize()
end)

-- when windower detects an event for an addon (//gk command) (most of this is 'borrowed' from equipviewer)
windower.register_event('addon command', function (...)
    config.reload(settings)
    coroutine.sleep(0.5)
    local cmd  = (...) and (...):lower() or ''
    local cmd_args = {select(2, ...)}
	
	if cmd == 'size' then
		if #cmd_args ~= 1 then
			error('Not enough arguments.')
			log('Current size: ' .. settings.text.size)
			return
		end
		
		settings.text.size = tonumber(cmd_args[1])
		config.save(settings)
		set_ui()
		log('Size changed to ' .. settings.text.size)
	elseif cmd == 'font' then
		if #cmd_args < 1 then
			error('Not enough arguments.')
			log('Current font: ' .. settings.text.font)
			return
		end
		
		settings.text.font = table.concat(cmd_args, ' ')
		config.save(settings)
		set_ui()
		log('Font changed to ' .. settings.text.font)
	elseif cmd == 'zone' then
		settings.display_zone = not settings.display_zone
		config.save(settings)
		set_ui()
		log('Display Zone is now set to ' .. tostring(settings.display_zone))
	elseif cmd == 'bold' then
		settings.flags.bold = not settings.flags.bold
		config.save(settings)
		set_ui()
		log('Bold is now set to ' .. tostring(settings.flags.bold))
	elseif cmd == 'italic' then
		settings.flags.italic = not settings.flags.italic
		config.save(settings)
		set_ui()
		log('Italic is now set to ' .. tostring(settings.flags.italic))
	elseif cmd == 'pad' then
		settings.pad_text = not settings.pad_text
		config.save(settings)
		set_ui()
		log('Pad Text is now set to ' .. tostring(settings.pad_text))
	elseif cmd == 'position' or cmd == 'pos' then
		if #cmd_args < 2 then
			error('Not enough arguments.')
			log('Current position: ' .. settings.pos.x .. ' ' .. settings.pos.y)
			return
		end

		settings.pos.x = tonumber(cmd_args[1])
		settings.pos.y = tonumber(cmd_args[2])
		config.save(settings)
		set_ui()
		log('Position changed to ' .. settings.pos.x .. ', ' .. settings.pos.y)
	elseif cmd == 'background' or cmd == 'bg' then
        if #cmd_args < 1 then
            error('Not enough arguments.')
            log(('Current BG color: RED:%d/255 GREEN:%d/255 BLUE:%d/255 ALPHA:%d/255 = %d%%'):format(
                settings.bg.red, settings.bg.green, settings.bg.blue, settings.bg.alpha, math.floor(settings.bg.alpha/255*100)
            ))
            return
        elseif #cmd_args == 1 then
            local alpha = tonumber(cmd_args[1])
            if alpha <= 1 and alpha > 0 then
                settings.bg.alpha = math.floor(255 * (alpha))
            else
                settings.bg.alpha = math.floor(alpha)
            end
        elseif #cmd_args >= 3 then
            settings.bg.red = tonumber(cmd_args[1])
            settings.bg.green = tonumber(cmd_args[2])
            settings.bg.blue = tonumber(cmd_args[3])
            if #cmd_args == 4 then
                local alpha = tonumber(cmd_args[4])
                if alpha <= 1 and alpha > 0 then
                    settings.bg.alpha = math.floor(255 * (alpha))
                else
                    settings.bg.alpha = math.floor(alpha)
                end
            end
        end
        
		config.save(settings)
		set_ui()
        log(('BG color changed to: RED:%d/255 GREEN:%d/255 BLUE:%d/255 ALPHA:%d/255 = %d%%'):format(
            settings.bg.red, settings.bg.green, settings.bg.blue, settings.bg.alpha, math.floor(settings.bg.alpha/255*100)
        ))
		
	elseif cmd == 'foreground' or cmd == 'fg' then
        if #cmd_args < 1 then
            error('Not enough arguments.')
            log(('Current Text color: RED:%d/255 GREEN:%d/255 BLUE:%d/255 ALPHA:%d/255 = %d%%'):format(
                settings.text.red, settings.text.green, settings.text.blue, settings.text.alpha, math.floor(settings.text.alpha/255*100)
            ))
            return
        elseif #cmd_args == 1 then
            local alpha = tonumber(cmd_args[1])
            if alpha <= 1 and alpha > 0 then
                settings.text.alpha = math.floor(255 * (alpha))
            else
                settings.text.alpha = math.floor(alpha)
            end
        elseif #cmd_args >= 3 then
            settings.text.red = tonumber(cmd_args[1])
            settings.text.green = tonumber(cmd_args[2])
            settings.text.blue = tonumber(cmd_args[3])
            if #cmd_args == 4 then
                local alpha = tonumber(cmd_args[4])
                if alpha <= 1 and alpha > 0 then
                    settings.text.alpha = math.floor(255 * (alpha))
                else
                    settings.text.alpha = math.floor(alpha)
                end
            end
        end
        
		config.save(settings)
		set_ui()
        log(('Foreground color changed to: RED:%d/255 GREEN:%d/255 BLUE:%d/255 ALPHA:%d/255 = %d%%'):format(
            settings.text.red, settings.text.green, settings.text.blue, settings.text.alpha, math.floor(settings.text.alpha/255*100)
        ))
	elseif cmd == 'debug' or cmd == 'd' then
		-- hax to make the debug message look right
		table.vprint(cmd_args)
		create_debug_text(table.concat(cmd_args, ' '):gsub('\\n', '\n'))
	else
        log('HELP:')
		log('gk zone: toggles displaying the zone')
        log('gk pos|position <xpos> <ypos>: move to position (from top left)')
        log('gk bg|background <red> <green> <blue> <alpha>: sets color and opacity of background (out of 255)')
        log('gk fg|foreground <red> <green> <blue> <alpha>: sets color and opacity of text (out of 255)')
		log('gk size <size>: sets the size of the text')
		log('gk font <font>: sets the font of the text')
		log('gk bold: toggles the font to/from bold')
		log('gk italic: toggles the font to/from italic')
		log('gk pad: toggles padding the text to the right NOTE: Recommended for monospace fonts only!')
    end
end)

-- remove the addon from the UI
function hide()
	if progress_text then
		progress_text:hide()
	end
end

-- add the addon to the UI
function show()
	if progress_text and progress_data ~= '' then
		progress_text:show()
	end
end

-- update the progress for a target
function update_count(data)
	data.count = math.min(data.count + 1, data.target_count)
	create_text()
end

-- check if target is a family vs a specific type
function is_family_member(text)
	return text:contains('member') and text:contains('family')
end

-- determine what to do with the recorded text
function parse_tokens(tokens, review)
	-- multi-target regime use  as a delimiter, so if we see it, we know it's a multi-target regime
	if tokens:contains('') then
		-- split the regime at the s
		for token in string.gmatch(tokens, '[^]+') do
			token = token:gsub('[^%w*%p*%s*]*', ''):gsub('%.%d', '.')
			-- and send it to be shown in the UI
			assign_regime(token, review)
		end
	else
		tokens = tokens:gsub('[^%w*%p*%s*]*', ''):gsub('%.%d', '.')
		-- if no , send the whole thing to the UI
		assign_regime(tokens, review)
	end
	create_text()
end

-- put the token into the regime list
function assign_regime(token, review)
	-- if we haven't gotten this token before (the messages are spammy)
	if not received_tokens:sconcat():contains(token) then
		-- record that we've gotten this token for the above line
		received_tokens:append(token)
		-- string manipulation magic. Touch at your own risk.
		local trimmed = token:trim():split('.')[1]
		local split = trimmed:split(' ')
		local nums = review and split[1]:split('/')
		local count = review and nums[1] or 0
		local target_count = review and nums[2] or split[1]
		local target_name = nil
		local target_family = nil
		
		-- used for setting the padding
		max_length = math.max(max_length, trimmed:len())
		
		local target_value = split:slice(2):concat(' ')
		if is_family_member(trimmed) then
			-- if it is a family
			target_family = target_value
		else
			-- if it is not a family
			target_name = target_value
		end
		
		-- add the target to the list
		targets:append({
			count = tonumber(count),
			target_count = tonumber(target_count),
			name = target_name,
			family = target_family,
		})
	end
	
	-- for if I ever get around to making this better and less global-dependent
	return targets
end

-- actually create the text object and display it
function create_text()
	-- if there are no targets... why are you here?
	if #targets < 1 then
		return
	end
	-- make sure progress_data is cleared
	progress_data = ''
	-- if we are showing the current zone
	if settings.display_zone then
		-- see if the zone's name is longer than the longest target string (looking at you, Bostaunieux Oubliette)
		max_length = math.max(zone:len(), max_length)
		-- try our best to put the zone's name in the middle. Maybe make a setting to configure zone padding?
		progress_data = zone:lpad(' ', (zone:len() + max_length) / 2):rpad(' ', (zone:len() + max_length) / 2) .. '\n'
	end
	-- for each target
	for _, data in pairs(targets) do
		-- format the text so it shows as something like (1/4 Tunnel Bats)
		local formatted_text = ('%d/%d %s\n'):format(data.count, data.target_count, data.name or data.family)
		-- if we want to pad the text
		if settings.pad_text then
			-- left-pad the text so that there are spaces which align it to the right side, even with the longest string (max_length)
			formatted_text = formatted_text:lpad(' ', max_length + 1)
		end
		-- append the new target to progress_data
		progress_data = progress_data .. formatted_text
	end
	-- set our STRING text to the UI text
	progress_text:text(progress_data)
	-- and make sure we can see it
	show()
end

-- just for testing purposes
function create_debug_text(text)
	progress_data = text
	progress_text:text(progress_data)
	show()
end