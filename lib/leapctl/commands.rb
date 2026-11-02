# frozen_string_literal: true

module Leapctl
  # Every user-facing operation, shared by the CLI and the MCP server. A command declares its
  # arguments and kind (:read, :control or :change) and returns lines of text. :change commands take a
  # backup first; the CLI asks for --yes and the MCP server for confirm: true before running them.
  module Commands
    Arg = Struct.new(:name, :desc, :required, :type) # type: :string, :number or :boolean
    Command = Struct.new(:name, :kind, :desc, :args, :run, :check)

    REGISTRY = {}

    # check: optional, runs before the backup, so a bad argument stops a change before anything happens.
    def self.define(name, kind, desc, args = [], check: nil, &run)
      REGISTRY[name] = Command.new(name, kind, desc, args.map { |a| Arg.new(*a) }, run, check)
    end

    def self.[](name)
      REGISTRY[name] or raise Error, "unknown command #{name.inspect} (see `leapctl help`)"
    end

    # Runs a command with a hash of arguments (string keys). Streams progress through the block.
    def self.call(client, name, args, &progress)
      cmd = self[name]
      cmd.args.each { |a| raise Error, "#{name}: missing #{a.name}" if a.required && args[a.name].to_s.empty? }
      cmd.check&.call(client, args)
      out = []
      if cmd.kind == :change
        backup = client.backup
        out << "backup: #{backup}"
      end
      writes = client.writes
      begin
        out.concat(Array(cmd.run.call(client, args, out, progress)))
      rescue StandardError
        # refused before anything was sent (a name not found, say): that backup would only make the
        # next `restore` a no-op
        File.delete(backup) if backup && client.writes == writes && File.exist?(backup)
        raise
      end
    end

    def self.bool(v)
      return v if v == true || v == false
      raise Error, 'auto_program must be true or false (on the command line: --auto-program or --no-auto-program)' unless %w[true false].include?(v.to_s)
      v.to_s == 'true'
    end

    def self.latest_backup(c)
      c.own_backups.first or raise Error, "no backups of this bridge yet in #{c.config.backup_dir}"
    end

    AREA = ['area', 'room name or href', true, :string].freeze
    AUTO = ['auto_program', 'true: keep what the AutoProgrammer assigns; false: clear it and restore everything else. Ask the user.', true, :boolean].freeze

    # Home Assistant's Lutron Caséta integration reads devices, names and rooms only when it starts or
    # is reloaded (Settings > Devices & services > Lutron Caséta > ⋮ > Reload).
    HA_NEW_DEVICE = 'Home Assistant: reload its Lutron Caséta integration to see the new device (it goes to the HA area named like its Lutron room).'
    HA_REMOVED = 'Home Assistant: reload its Lutron Caséta integration, then delete the device there (Home Assistant refuses before the reload).'
    HA_NAMES = 'Home Assistant: reload its Lutron Caséta integration to show the new names; entity IDs and HA areas stay as they are.'
    HA_ZONE = 'Home Assistant names Caséta and RA2 Select lights after their device, so this name doesn\'t appear there (rename-device does).'
    HA_UNDERSCORE = 'Note: Home Assistant shows only the part of a Lutron device name after its last "_".'

    def self.underscore_note(name)
      name.to_s.include?('_') ? [HA_UNDERSCORE] : []
    end

    # ---- read -----------------------------------------------------------------------------------

    define('doctor', :read, 'Check the connection, permissions and the health of the system') do |c, _a|
      st = c.read('/system/status')&.dig('SystemStatus') || {}
      server = c.read('/server/1')&.dig('Server') || {}
      role = c.read('/clientsetting')&.dig('ClientSetting', 'Permissions', 'SessionRole')
      project = c.read('/project')&.dig('Project') || {}
      lines = ["bridge #{c.config.host}: #{project['ProductType'] || 'unknown product'}, LEAP #{server['ProtocolVersion'] || '?'}",
               "bridge certificate: #{c.config.ca ? "checked against #{File.basename(c.config.ca)}" : 'not checked (no CA file: setup from Home Assistant adds it, or --ca=<file>)'}",
               "session role: #{role || 'unknown'}#{role == 'Admin' ? '' : ' (programming changes need Admin)'}",
               "#{c.devices.size} devices, #{c.zones.size} zones, #{c.areas.size - 1} rooms, #{c.schedule_events.size} schedules",
               "pairing mode: #{st['InAssociationMode'] ? 'ON (run `leapctl pair` or the app to finish)' : 'off'}"]
      failing = (c.read('/device/status')&.dig('DeviceStatuses') || []).reject do |s|
        s['ConfigurationTransferStatus'].to_s.empty? || s['ConfigurationTransferStatus'] == 'NotRequired'
      end
      failing.each do |s|
        d = c.device(s.dig('Device', 'href'))
        lines << "WARN #{d ? c.device_label(d) : s.dig('Device', 'href')}: settings not delivered (#{s.dig('FailedTransfers', 'Count')} failed attempts); check power and range"
      end
      c.template_drift.each { |b| lines << "WARN #{b}: differs from its Lutron template; the AutoProgrammer may overwrite it" }
      autoprog = (c.read('/service')&.dig('Services') || []).find { |s| s['Type'] == 'AutoProgrammer' }
      lines << "AutoProgrammer: #{autoprog&.dig('AutoProgrammerProperties', 'EnabledState') || 'not present'}"
      lines << (lines.any? { |l| l.start_with?('WARN') } ? 'done, with warnings' : 'all good')
    end

    define('devices', :read, 'List devices with type and serial number') do |c, _a|
      c.devices.map { |d| "#{d['href'].ljust(12)} #{d['DeviceType'].to_s.ljust(26)} #{d['SerialNumber'].to_s.ljust(10)} #{c.device_label(d)}" }
    end

    define('rooms', :read, 'List rooms (areas)') do |c, _a|
      c.areas.reject { |a| a.dig('Parent', 'href').nil? }.map { |a| "#{a['href'].ljust(10)} #{a['Name']}" }
    end

    define('zones', :read, 'List lights, switches and fans with their current level') do |c, _a|
      c.zones.map do |z|
        st = c.read("#{z['href']}/status")&.dig('ZoneStatus') || {}
        "#{z['href'].ljust(10)} #{z['ControlType'].to_s.ljust(9)} #{(st['Level'] || st['FanSpeed']).to_s.rjust(6)}  #{c.zone_label(z['href'])}"
      end
    end

    define('programming', :read, 'What every button does (or one remote)', [['device', 'remote name or href', false, :string]]) do |c, a|
      devs = a['device'].to_s.empty? ? c.button_devices : [c.find_remote(a['device'])]
      devs.flat_map do |d|
        kind = c.column_group(d) ? 'one set of lights for all buttons' : (d['EngravingKit'] && d['EngravingKit'] != 'Custom' ? "follows #{d['EngravingKit']} templates" : 'each button separately')
        ["#{c.device_label(d)}  (#{d['href']}, #{d['DeviceType']}, #{kind})"] +
          c.device_programming(d).map do |b|
            acts = c.sort_actions(b[:actions]) { |x| [x[:zone], x[:level]] }.map { |x| "#{c.zone_label(x[:zone])} → #{b[:direction] ? b[:direction].downcase : x[:level]}" }
            "  #{"#{b[:name]} (#{b[:button]})".ljust(28)} #{acts.empty? ? '— nothing in Lutron' : acts.join('; ')}"
          end
      end
    end

    define('schedules', :read, 'Lutron schedules (timeclock events) and what they do') do |c, _a|
      c.schedule_events.flat_map do |e|
        acts = c.stored_actions(e['href']).map { |x| "#{c.zone_label(x.dig('AffectedZone', 'href'))} → #{x['Level']}" }
        ["#{e['href'].ljust(18)} #{e['Name'].to_s.ljust(24)} #{c.describe_days(e).ljust(9)} #{c.describe_time(e).ljust(14)} #{c.schedule_status(e['href'])}",
         "    #{acts.empty? ? '— no lights' : acts.join('; ')}"]
      end
    end

    BACKUP = ['backup', 'a backup\'s file name, as `backups` lists it', false, :string].freeze

    define('backups', :read, 'List backups (newest last)') do |c, _a|
      c.backups.last(20)
    end

    define('backup', :read, 'Save a backup of all programming now') do |c, _a|
      [c.backup]
    end

    UNDO_LIMITS = 'Covers only which lights existing buttons, templates, scenes and schedules control: not names, rooms, ' \
                  'moves, schedule times, days or on/off, trim, or anything added or deleted since the backup'

    define('diff', :read, "Compare with a backup (default: this bridge's latest). #{UNDO_LIMITS}", [BACKUP]) do |c, a|
      changes = c.restore(a['backup'].to_s.empty? ? latest_backup(c) : a['backup'], dry_run: true)
      changes.empty? ? ['no differences'] : changes
    end

    define('get', :read, 'Raw read of any LEAP URL', [['url', 'e.g. /device/5', true, :string]]) do |c, a|
      [JSON.pretty_generate(c.read(a['url']))]
    end

    # ---- control --------------------------------------------------------------------------------

    define('level', :control, 'Set a light to a level', [['zone', 'light name or href', true, :string], ['level', '0-100', true, :number], ['fade', 'seconds', false, :number]]) do |c, a|
      c.set_level(c.find_zone(a['zone']), a['level'], a['fade']); ['ok']
    end

    define('fan', :control, 'Set a fan speed', [['zone', 'fan name or href', true, :string], ['speed', 'Off, Low, Medium, MediumHigh or High', true, :string]]) do |c, a|
      c.set_fan(c.find_zone(a['zone']), a['speed']); ['ok']
    end

    define('press', :control, 'Press and release a button (runs its Lutron programming)', [['button', '/button/N', true, :string]]) do |c, a|
      c.press(a['button']); ['ok']
    end

    # ---- changes --------------------------------------------------------------------------------

    TARGET = ['target', 'a 3-button raise/lower Pico (name or href), /button/N, /timeclockevent/N, a schedule name or /virtualbutton/N', true, :string].freeze
    ZONE = ['zone', 'light name or href', true, :string].freeze

    define('assign', :change, 'Make a button, Pico, schedule or scene control a light (or change its level)',
           [TARGET, ZONE, ['level', '0-100, default 100', false, :number], ['fade', 'seconds, default 2', false, :number], ['delay', 'seconds, default 0', false, :number]]) do |c, a|
      [c.assign(c.find_target(a['target']), c.find_zone(a['zone']), a['level'] || 100, a['fade'] || 2, a['delay'] || 0)]
    end

    define('unassign', :change, 'Stop a target controlling a light; target "all" removes it everywhere', [TARGET, ZONE]) do |c, a|
      z = c.find_zone(a['zone'])
      done = a['target'] == 'all' ? c.unassign_everywhere(z) : c.unassign(c.find_target(a['target']), z)
      done.empty? ? ['nothing to remove'] : done.map { |x| "removed from #{x}" }
    end

    define('clear-button', :change, 'Remove all Lutron actions from a button; on an engraved Pico also from its room template and every remote sharing it (presses still reach Home Assistant)', [['button', '/button/N', true, :string]]) do |c, a|
      [c.clear_button(a['button'])]
    end

    define('rename-device', :change, 'Rename a device', [['device', 'name or href', true, :string], ['name', 'new name', true, :string]]) do |c, a|
      c.rename_device(c.find_device(a['device'])['href'], a['name'])
      ['ok', HA_NAMES] + underscore_note(a['name'])
    end

    define('rename-zone', :change, 'Rename a light/zone', [ZONE, ['name', 'new name', true, :string]]) do |c, a|
      c.rename_zone(c.find_zone(a['zone']), a['name']); ['ok', HA_ZONE]
    end

    define('rename-room', :change, 'Rename a room', [AREA, ['name', 'new name', true, :string]]) do |c, a|
      c.rename_area(c.find_area(a['area']), a['name']); ['ok', HA_NAMES]
    end

    define('room-add', :change, 'Create a room', [['name', 'room name', true, :string]]) do |c, a|
      [c.add_area(a['name'])]
    end

    define('room-delete', :change, 'Delete an empty room', [AREA]) do |c, a|
      c.delete_area(c.find_area(a['area'])); ['ok']
    end

    define('move-device', :change, 'Move a device to another room (this runs the AutoProgrammer)', [['device', 'name or href', true, :string], AREA, AUTO]) do |c, a, out|
      before = out.first.sub('backup: ', '')
      auto = bool(a['auto_program'])
      changes = c.move_device(c.find_device(a['device'])['href'], c.find_area(a['area']), auto_program: auto, before_backup: before)
      lines = if changes.empty? then ['moved; no other programming changed']
              elsif auto then ['moved; the AutoProgrammer also changed (undo with restore):'] + changes
              else ['moved; undid what the AutoProgrammer changed:'] + changes
              end
      lines + [HA_NAMES]
    end

    define('trim', :change, 'Set a dimmer\'s high-end and low-end trim (%)', [ZONE, ['high', '%', true, :number], ['low', '%', true, :number]]) do |c, a|
      c.set_trim(c.find_zone(a['zone']), a['high'], a['low']); ['ok']
    end

    define('schedule-add', :change, 'Create a schedule (then assign lights to it)',
           [['name', 'schedule name', true, :string], ['days', 'daily, weekdays, weekends or Mon,Wed,...', true, :string], ['time', 'HH:MM, sunrise, sunset-30, sunset+15', true, :string]]) do |c, a|
      [c.add_schedule(a['name'], a['days'], a['time'])]
    end

    EVENT = ['schedule', 'schedule name or href', true, :string].freeze
    define('schedule-time', :change, 'Change when a schedule runs', [EVENT, ['time', 'HH:MM, sunrise, sunset-30', true, :string]]) do |c, a|
      c.update_schedule(c.find_event(a['schedule']), c.parse_time(a['time'])); ['ok']
    end
    define('schedule-days', :change, 'Change the days a schedule runs', [EVENT, ['days', 'daily, weekdays, weekends or Mon,Wed,...', true, :string]]) do |c, a|
      c.update_schedule(c.find_event(a['schedule']), c.parse_days(a['days'])); ['ok']
    end
    define('schedule-rename', :change, 'Rename a schedule', [EVENT, ['name', 'new name', true, :string]]) do |c, a|
      c.update_schedule(c.find_event(a['schedule']), 'Name' => a['name']); ['ok']
    end
    define('schedule-enable', :change, 'Turn a schedule on', [EVENT]) do |c, a|
      c.enable_schedule(c.find_event(a['schedule']), true); ['ok']
    end
    define('schedule-disable', :change, 'Turn a schedule off (keeps it)', [EVENT]) do |c, a|
      c.enable_schedule(c.find_event(a['schedule']), false); ['ok']
    end
    define('schedule-delete', :change, 'Delete a schedule', [EVENT]) do |c, a|
      c.delete_schedule(c.find_event(a['schedule'])); ['ok']
    end

    define('restore', :change, "Go back to a backup (default: this bridge's one before the latest). #{UNDO_LIMITS}; undo those with the matching command",
           [BACKUP], check: ->(c, a) { c.backup_path(a['backup']) unless a['backup'].to_s.empty? }) do |c, a, out|
      file = a['backup'].to_s.empty? ? c.own_backups.first(2)[1] || latest_backup(c) : a['backup']
      done = c.restore(file, dry_run: false)
      done.empty? ? ["nothing to restore (#{File.basename(file)})"] : ["restored #{File.basename(file)}:"] + done
    end

    define('remove-device', :change, 'Delete a device from the system (it can be paired again)', [['device', 'name or href', true, :string]]) do |c, a|
      d = c.find_device(a['device']); c.remove_device(d['href']); ["removed #{c.device_label(d)}", HA_REMOVED]
    end

    # Pairing stays well inside a client's limit for one tool call (the plugin allows 30 minutes).
    MINUTES = ->(_c, a) { raise Error, 'pair: minutes must be more than 0 and at most 10' unless a['minutes'].nil? || (0.01..10).cover?(Float(a['minutes'])) }

    define('pair', :change, 'Add devices: hold the new device\'s button until it flashes rapidly',
           [AREA, AUTO, ['name', 'name for the new device', false, :string], ['minutes', 'how long to listen: at most 10, default 3', false, :number]],
           check: MINUTES) do |c, a, out, progress|
      before = out.first.sub('backup: ', '')
      auto = bool(a['auto_program'])
      area = c.find_area(a['area'])
      minutes = Float(a['minutes'] || 3)
      progress&.call("pairing into #{c.area_name(area)} for #{minutes.round(1)} min: hold the device's button until it flashes rapidly")
      found, changes = c.pair(minutes, auto_program: auto, before_backup: before, area_href: area, name: a['name']) { |m| progress&.call(m) }
      next ['no new devices heard'] if found.empty?
      lines = found.flat_map do |h|
        d = c.device(h)
        ["#{c.device_label(d)} (#{h}):"] + c.device_programming(d).map do |b|
          "  #{b[:name]}: #{c.sort_actions(b[:actions]) { |x| [x[:zone], x[:level]] }.map { |x| "#{c.zone_label(x[:zone])} → #{x[:level]}" }.join('; ').then { |s| s.empty? ? '—' : s }}"
        end
      end
      lines += if changes.empty? then ['other remotes unchanged']
               elsif auto then ['the AutoProgrammer also changed (undo with restore):'] + changes
               else ['undid what the AutoProgrammer changed elsewhere:'] + changes
               end
      lines + [HA_NEW_DEVICE] + underscore_note(a['name'])
    end
  end
end
