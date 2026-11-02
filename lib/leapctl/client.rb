# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'

module Leapctl
  # The bridge's data model and every operation leapctl knows, on top of a transport (TlsTransport,
  # or a fake one in the tests). Reads are cached per Client; any write clears the cache.
  #
  # Programming, in Lutron's terms:
  # * Buttons have a programming model with one or more presets; a preset holds preset assignments
  #   (a zone, a level, fade and delay seconds).
  # * "Column" button groups (3-button raise/lower Picos) keep one list of affected zones for the whole
  #   remote and derive every button from it; edit /buttongroup/N/affectedzone, not the buttons.
  # * Engraved Picos (EngravingKit other than Custom) mirror per-room templates (/vbutton/N, e.g.
  #   Kitchen/Dining). Lutron's AutoProgrammer copies the templates onto the buttons again after a device
  #   is paired or moved, so an edit only lasts if the template gets it too; assign/unassign do both.
  # * Schedules (/timeclockevent) and scenes (/virtualbutton) program lights the same way.
  class Client
    DAYS = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday].freeze

    attr_reader :config, :writes

    def self.open(config = Config.load, **opts)
      client = new(config, **opts)
      return client unless block_given?
      begin
        yield client
      ensure
        client.close
      end
    end

    # settle: seconds to wait for the AutoProgrammer after pairing or moving a device.
    def initialize(config = Config.load, transport: nil, settle: 30)
      @config = config
      @transport = transport
      @settle = settle
      @cache = {}
      @writes = 0 # write requests sent: a change that sent none hasn't touched the system
    end

    def close
      @transport&.close
    end

    def request(type, url, body = nil)
      transport.request(type, url, body)
    end

    # Connects on first use, so commands that only read local files (backups) work without the bridge.
    def transport
      @transport ||= TlsTransport.new(config.host, config.cert, config.key, ca: config.ca)
    end

    def status(resp)
      resp.dig('Header', 'StatusCode').to_s
    end

    # Body of a successful read (cached), nil on 204 or 4xx.
    def read(url)
      return @cache[url] if @cache.key?(url)
      resp = request('ReadRequest', url)
      @cache[url] = status(resp).start_with?('200') ? resp['Body'] : nil
    end

    def write!(type, url, body = nil)
      @writes += 1
      resp = request(type, url, body)
      @cache.clear
      raise Error, "#{type} #{url}: #{status(resp)} #{resp['Body'].to_json}" unless status(resp) =~ /^20\d/
      resp['Body']
    end

    def refresh
      @cache.clear
    end

    # ---- model ---------------------------------------------------------------------------------

    def areas
      read('/area')&.dig('Areas') || []
    end

    def devices
      read('/device')&.dig('Devices') || []
    end

    def zones
      read('/zone')&.dig('Zones') || []
    end

    # Scenes (/virtualbutton/N) and the templates of engraved remotes (/vbutton/N) come in one list.
    def virtual_buttons
      read('/virtualbutton')&.dig('VirtualButtons') || []
    end

    def templates
      virtual_buttons.select { |v| v['href'].start_with?('/vbutton/') }
    end

    def schedule_events
      read('/timeclockevent')&.dig('TimeclockEvents') || []
    end

    def area_name(href)
      areas.find { |a| a['href'] == href }&.dig('Name')
    end

    def device(href)
      devices.find { |d| d['href'] == href }
    end

    def zone(href)
      zones.find { |z| z['href'] == href }
    end

    def device_label(dev)
      (dev['FullyQualifiedName'] || [dev['Name']]).join(' / ')
    end

    def zone_label(href)
      z = zone(href) or return href
      dev = device(z.dig('Device', 'href'))
      dev ? device_label(dev) : z['Name']
    end

    LISTED_BY = { 'device' => 'devices', 'remote' => 'programming', 'zone' => 'zones', 'room' => 'rooms', 'schedule' => 'schedules' }.freeze

    # Finds one item by href, exact name, or unique name fragment.
    def pick(items, arg, kind)
      exact = items.select { |i| i[:href] == arg || i[:name].casecmp?(arg.to_s) }
      exact = items.select { |i| i[:name].split(' / ').last.casecmp?(arg.to_s) } if exact.empty? # "Lamp" for "Den / Lamp"
      return exact.first[:href] if exact.size == 1
      part = items.select { |i| i[:name].downcase.include?(arg.to_s.downcase) }
      return part.first[:href] if part.size == 1
      raise Error, "#{kind} #{arg.inspect}: #{part.empty? ? "not found (`leapctl #{LISTED_BY[kind]}` lists them)" : "ambiguous (#{part.map { |i| i[:name] }.join(', ')})"}"
    end

    def find_device(arg)
      device(pick(devices.map { |d| { href: d['href'], name: device_label(d) } }, arg, 'device'))
    end

    # Like find_device, among the remotes and keypads only (so a room's name finds its one Pico).
    def find_remote(arg)
      device(pick(button_devices.map { |d| { href: d['href'], name: device_label(d) } }, arg, 'remote'))
    end

    def find_zone(arg)
      pick(zones.map { |z| { href: z['href'], name: zone_label(z['href']) } }, arg, 'zone')
    end

    def find_area(arg)
      pick(areas.reject { |a| a.dig('Parent', 'href').nil? }.map { |a| { href: a['href'], name: a['Name'] } }, arg, 'room')
    end

    def find_event(arg)
      pick(schedule_events.map { |e| { href: e['href'], name: e['Name'] } }, arg, 'schedule')
    end

    # A programming target given as an href or a name: a schedule name, else a remote's name.
    def find_target(arg)
      return arg if arg.start_with?('/')
      find_event(arg)
    rescue Error
      find_remote(arg)['href']
    end

    # All preset hrefs a programming model points at (SingleAction, AdvancedToggle, DualAction, Raise/Lower).
    def preset_hrefs(pm)
      pm.flat_map do |k, v|
        if k.include?('Preset') then v.is_a?(Array) ? v.map { |x| x['href'] } : [v.is_a?(Hash) ? v['href'] : nil]
        elsif v.is_a?(Hash) && k.end_with?('Properties') then preset_hrefs(v) # DualActionProperties
        else []
        end
      end.compact
    end

    def assignments(preset_href)
      read("#{preset_href}/presetassignment")&.dig('PresetAssignments') || []
    end

    # Presets of a button, schedule, scene or template.
    def presets_of(owner_href)
      pm_href = read(owner_href)&.values&.first&.dig('ProgrammingModel', 'href') or return []
      preset_hrefs(read(pm_href)&.dig('ProgrammingModel') || {})
    end

    def action_set(target)
      presets_of(target).flat_map { |p| assignments(p) }.map { |a| [a.dig('AffectedZone', 'href'), a['Level']] }.sort_by(&:to_s)
    end

    def button_groups(dev)
      (dev['ButtonGroups'] || []).map { |bg| read(bg['href'])['ButtonGroup'] }
    end

    def column_group(dev)
      button_groups(dev).find { |g| g['ProgrammingType'] == 'Column' }
    end

    # [{button:, number:, name:, group:, model:, direction:, actions: [{href:, zone:, level:, fade:, delay:}]}]
    def device_programming(dev)
      button_groups(dev).flat_map do |group|
        (group['Buttons'] || []).map do |b|
          btn = read(b['href'])['Button']
          pm = read(btn.dig('ProgrammingModel', 'href'))&.dig('ProgrammingModel') || {}
          actions = preset_hrefs(pm).flat_map do |p|
            assignments(p).map do |a|
              { href: a['href'], preset: p, zone: a.dig('AffectedZone', 'href'), level: a['Level'],
                fade: a['Fade'], delay: a['Delay'] }
            end
          end
          { button: btn['href'], number: btn['ButtonNumber'], name: btn['Name'], group: group['ProgrammingType'],
            model: pm['ProgrammingModelType'], direction: pm['Direction'], actions: actions }
        end
      end
    end

    def button_devices
      devices.select { |d| d['ButtonGroups'] }
    end

    def schedule_status(href)
      read("#{href}/status")&.dig('TimeclockEventStatus', 'EnableState')
    end

    def describe_time(e)
      if e['TimeclockEventType'] == 'Astronomic'
        # the offset is minutes:seconds, e.g. "-30:00" = 30 minutes before
        off = e['AstronomicTimeOffset'].to_s =~ /\A(-?)(\d+):(\d+)\z/ ? ($2.to_i.zero? ? '' : " #{$1.empty? ? '+' : '-'}#{$2.to_i} min") : ''
        "#{e['AstronomicEventType'].to_s.downcase}#{off}"
      else
        format('%02d:%02d', e.dig('TimeOfDay', 'Hour').to_i, e.dig('TimeOfDay', 'Minute').to_i)
      end
    end

    def describe_days(e)
      on = DAYS.select { |d| e[d] }
      return 'daily' if on.size == 7
      return 'weekdays' if on == DAYS[1..5]
      return 'weekends' if on == %w[Sunday Saturday]
      on.map { |d| d[0, 3] }.join(',')
    end

    # ---- templates of engraved remotes ---------------------------------------------------------

    # The template a button follows: same room and engraving as its device, and the same lights.
    # Returns its href, :unclear (several or none match), or nil (not an engraved remote).
    # A template belongs to a room, an engraving and a button number, and every engraved remote of
    # that engraving in that room with that button number follows it (two remotes can share one).
    # Returns the template href; falls back to matching lights; :unclear if that's ambiguous too;
    # nil if the button isn't on an engraved remote.
    def linked_template(button_href)
      btn, dev = button_and_device(button_href)
      return nil unless dev && engraved?(dev)
      mine = templates_for(dev)
      by_number = mine.select { |v| v['ButtonNumber'] == btn['ButtonNumber'] }
      return by_number.first['href'] if by_number.size == 1
      set = action_set(button_href)
      by_lights = mine.select { |v| action_set(v['href']) == set }
      by_lights.size == 1 ? by_lights.first['href'] : :unclear
    end

    # Buttons (of any remote) that follow a template.
    def template_buttons(template_href)
      t = templates.find { |v| v['href'] == template_href } or return []
      button_devices.select { |d| engraved?(d) && templates_for(d).include?(t) }.flat_map do |d|
        device_programming(d).select { |b| b[:number] == t['ButtonNumber'] }.map { |b| b[:button] }
      end
    end

    # Engraved-remote buttons that differ from their template: the AutoProgrammer would overwrite them.
    def template_drift
      button_devices.select { |d| engraved?(d) }.flat_map do |d|
        device_programming(d).select do |b|
          t = linked_template(b[:button])
          t.is_a?(String) && action_set(t) != action_set(b[:button])
        end.map { |b| "#{device_label(d)} #{b[:name]}" }
      end
    end

    def engraved?(dev)
      !dev['EngravingKit'].nil? && dev['EngravingKit'] != 'Custom'
    end

    def templates_for(dev)
      templates.select { |v| v.dig('Parent', 'href') == dev.dig('AssociatedArea', 'href') && v.dig('Category', 'Type') == dev['EngravingKit'] }
    end

    def button_and_device(button_href)
      btn = read(button_href)&.dig('Button') or return [nil, nil]
      [btn, device(read(btn.dig('Parent', 'href').to_s)&.dig('ButtonGroup', 'Parent', 'href').to_s)]
    end

    # ---- backups -------------------------------------------------------------------------------

    # Everything leapctl can restore, plus context. Actions are sorted (by light, then level) and leave
    # out the assignments' own hrefs: the bridge lists actions in no fixed order and renumbers an
    # assignment whenever Lutron re-creates it, so two snapshots of the same programming are identical.
    def snapshot
      {
        taken_at: Time.now.iso8601,
        project: read('/project')&.dig('Project'),
        system: { status: read('/system/status'), away: read('/system/away'), services: read('/service'), link: links },
        areas: areas,
        devices: devices,
        zones: zones,
        column_groups: button_devices.each_with_object({}) do |d, h|
          g = column_group(d) and h[d['href']] = sort_actions((g['AffectedZones'] || []).map { |z| z.dig('Zone', 'href') }) { |z| [z, 0] }
        end,
        programming: button_devices.to_h do |d|
          [d['href'], device_programming(d).map do |b|
            b.merge(actions: sort_actions(b[:actions].map { |a| a.reject { |k, _| k == :href } }) { |a| [a[:zone], a[:level]] })
          end]
        end,
        schedules: schedule_events.map { |e| e.merge('EnableState' => schedule_status(e['href']), 'Actions' => stored_actions(e['href'])) },
        virtual_buttons: virtual_buttons.map { |vb| vb.merge('Actions' => stored_actions(vb['href'])) },
        occupancy_groups: (read('/occupancygroup')&.dig('OccupancyGroups') || []).map { |o| o.merge('Actions' => stored_actions(o['href'])) }
      }
    end

    # The RF links, without anything but their numbers and channel: on Clear Connect Type X systems
    # (RadioRA 3, HomeWorks) /link may also hold the network's key, which has no place in a backup.
    def links
      body = read('/link') or return nil
      { 'Links' => (body['Links'] || []).map { |l| l.select { |k, _| %w[href Parent LinkType LinkNumber RFProperties].include?(k) } } }
    end

    # A schedule's, scene's, template's or occupancy group's assignments, the way a snapshot keeps them.
    def stored_actions(owner_href)
      list = presets_of(owner_href).flat_map { |p| assignments(p) }.map { |a| a.reject { |k, _| k == 'href' } }
      sort_actions(list) { |a| [a.dig('AffectedZone', 'href'), a['Level']] }
    end

    # Sorts by zone number (/zone/9 before /zone/10), then level, then the rest, for a stable order.
    def sort_actions(list)
      list.sort_by do |a|
        zone, level = yield(a)
        [zone.to_s[/\d+\z/].to_i, zone.to_s, level.to_f, a.to_s]
      end
    end

    # Writes <backup_dir>/<time>.json, and the snapshot path if configured (without the time, so a
    # git-tracked copy changes only with the programming). Both are readable by you only. Returns the
    # backup path.
    def backup
      snap = snapshot
      FileUtils.mkdir_p(config.backup_dir, mode: 0o700)
      path = File.join(config.backup_dir, "#{Time.now.strftime('%Y%m%d-%H%M%S')}.json")
      path = path.sub('.json', "-#{rand(1000)}.json") if File.exist?(path)
      private_write(path, pretty(snap))
      if config.snapshot
        FileUtils.mkdir_p(File.dirname(config.snapshot))
        private_write(config.snapshot, pretty(snap.reject { |k, _| k == :taken_at }))
      end
      path
    end

    # Empty lists come out as [] and {} on every Ruby (older json versions spread them over lines). JSON
    # strings can't hold a raw line break, so this only touches the layout, never a name.
    def pretty(data)
      JSON.pretty_generate(data).gsub(/\[\n\s*\]/, '[]').gsub(/\{\n\s*\}/, '{}')
    end

    def private_write(path, text)
      File.write(path, text, perm: 0o600)
      File.chmod(0o600, path) rescue nil # perm: only applies to a new file
    end

    BACKUP_NAME = /\A\d{8}-\d{6}(-\d+)?\.json\z/.freeze

    def backups
      Dir[File.join(config.backup_dir, '*.json')].select { |f| File.basename(f) =~ BACKUP_NAME }.sort
    end

    # Which bridge a snapshot belongs to: its project's GUID (every backup has it), else the serial
    # number of /device/1 (the bridge or main repeater).
    def self.bridge_of(snap)
      snap.dig('project', 'GUID') || (snap['devices'] || []).find { |d| d['href'] == '/device/1' }&.dig('SerialNumber')
    end

    def bridge
      read('/project')&.dig('Project', 'GUID') || device('/device/1')&.dig('SerialNumber')
    end

    # This bridge's backups, newest first; a shared folder may also hold other bridges' backups.
    def own_backups
      id = bridge.to_s
      backups.reverse.lazy.select do |path|
        other = (self.class.bridge_of(JSON.parse(File.read(path, encoding: 'UTF-8'))) rescue nil)
        other.nil? || id.empty? || other.to_s == id
      end
    end

    # A backup by its file name (as `backups` lists it) or path. Only leapctl's own backups and the
    # snapshot file are read, and an error never quotes a file's content.
    def backup_path(name)
      path = File.expand_path(name.to_s, config.backup_dir)
      real = File.file?(path) ? File.realpath(path) : nil
      dir = File.directory?(config.backup_dir) ? File.realpath(config.backup_dir) : nil
      snap = config.snapshot && File.file?(config.snapshot) ? File.realpath(config.snapshot) : nil
      return real if real && ((dir && real.start_with?(dir + File::SEPARATOR)) || real == snap)
      raise Error, "no backup #{name} (see `leapctl backups`)"
    end

    def load_backup(name)
      snap = JSON.parse(File.read(backup_path(name), encoding: 'UTF-8'))
      raise JSON::ParserError unless snap.is_a?(Hash) && snap.key?('programming')
      snap
    rescue JSON::ParserError
      raise Error, "#{File.basename(name.to_s)} isn't a leapctl backup"
    end

    # Programming in a comparable shape, keyed by target: "column:/device/N" => zones, or a button,
    # template, scene or schedule href => [[zone, level, fade, delay], ...]. Takes a parsed snapshot
    # (string keys), so it works on backup files too.
    def self.programming_state(snap)
      st = {}
      cols = snap['column_groups'] || {}
      cols.each { |dev, zs| st["column:#{dev}"] = zs.sort }
      (snap['programming'] || {}).each do |dev, btns|
        next if cols.key?(dev)
        btns.each do |b|
          next if b['group'] == 'Column'
          st[b['button']] = b['actions'].map { |a| [a['zone'], a['level'], a['fade'], a['delay']] }.sort_by(&:to_s)
        end
      end
      ((snap['virtual_buttons'] || []) + (snap['schedules'] || [])).each do |v|
        st[v['href']] = (v['Actions'] || []).map { |a| [a.dig('AffectedZone', 'href'), a['Level'], a['Fade'], a['Delay']] }.sort_by(&:to_s)
      end
      st
    end

    # Puts programming back to a backup: removes what was added, re-adds what was removed, fixes levels.
    # Targets that no longer exist are skipped. Returns the changes (made unless dry_run).
    def restore(backup, dry_run: true)
      snap = load_backup(backup)
      theirs = self.class.bridge_of(snap).to_s
      raise Error, "#{File.basename(backup.to_s)} is a backup of another bridge" unless theirs.empty? || bridge.to_s.empty? || theirs == bridge.to_s
      want = self.class.programming_state(snap)
      have = self.class.programming_state(JSON.parse(JSON.generate(snapshot)))
      column_buttons = button_devices.select { |d| column_group(d) }.flat_map { |d| device_programming(d).map { |b| b[:button] } }
      changes = []
      want.each do |key, wz|
        hz = have[key]
        next if hz.nil? || hz == wz || column_buttons.include?(key)
        if key.start_with?('column:')
          dev = key.sub('column:', '')
          name = device_label(device(dev))
          (hz - wz).each { |z| changes << ["#{name}: remove #{zone_label(z)}", -> { unassign_one(dev, z) }] }
          (wz - hz).each { |z| changes << ["#{name}: add #{zone_label(z)}", -> { assign_one(dev, z) }] }
        else
          (hz.map(&:first) - wz.map(&:first)).each { |z| changes << ["#{key}: remove #{zone_label(z)}", -> { unassign_one(key, z) }] }
          wz.each do |z, lvl, fade, delay|
            cur = hz.find { |x| x[0] == z }
            next if cur == [z, lvl, fade, delay]
            changes << ["#{key}: #{cur ? 'set' : 'add'} #{zone_label(z)} → #{lvl}", -> { assign_one(key, z, lvl, fade || 2, delay || 0) }]
          end
        end
      end
      changes.each { |_, fn| fn.call } unless dry_run
      changes.map(&:first)
    end

    # ---- control -------------------------------------------------------------------------------

    def set_level(zone_href, level, fade = nil)
      params = [{ Type: 'Level', Value: Integer(level) }]
      params << { Type: 'FadeTime', Value: fade.to_s } if fade
      write!('CreateRequest', "#{zone_href}/commandprocessor", { Command: { CommandType: 'GoToLevel', Parameter: params } })
    end

    def set_fan(zone_href, speed)
      write!('CreateRequest', "#{zone_href}/commandprocessor",
             { Command: { CommandType: 'GoToFanSpeed', FanSpeedParameters: { FanSpeed: speed } } })
    end

    def press(button_href)
      write!('CreateRequest', "#{button_href}/commandprocessor", { Command: { CommandType: 'PressAndRelease' } })
    end

    # ---- programming ---------------------------------------------------------------------------

    def rename_device(href, name)
      write!('UpdateRequest', href, { Device: { Name: name } })
    end

    def rename_area(href, name)
      write!('UpdateRequest', href, { Area: { Name: name } })
    end

    def rename_zone(href, name)
      write!('UpdateRequest', href, { Zone: { Name: name } })
    end

    def add_area(name)
      root = areas.find { |a| a.dig('Parent', 'href').nil? }&.dig('href') || '/area/1'
      write!('CreateRequest', '/area', { Area: { Name: name, Parent: { href: root } } })['Area']['href']
    end

    def delete_area(href)
      raise Error, "#{area_name(href)} still has devices" if read(href)['Area']['AssociatedDevices'].to_a.any?
      write!('DeleteRequest', href)
    end

    # Moving a device to another room makes the AutoProgrammer treat it as newly placed: it adds the
    # device to templates of that room and re-copies templates onto engraved remotes. With
    # auto_program false those changes are undone (back to before_backup). Returns the changes.
    def move_device(device_href, area_href, auto_program:, before_backup:)
      write!('UpdateRequest', device_href, { Device: { AssociatedArea: { href: area_href } } })
      sleep @settle
      refresh
      restore(before_backup, dry_run: auto_program)
    end

    def set_trim(zone_href, high, low)
      write!('UpdateRequest', "#{zone_href}/tuningsettings", { TuningSettings: { HighEndTrim: Float(high), LowEndTrim: Float(low) } })
    end

    # Adds a light to a target: a Column Pico (device href; all its buttons), or a button, template,
    # scene or schedule (updates the level if the light is already there). On an engraved remote's
    # button the linked template gets the same change. Returns a description.
    # On an engraved remote's button the change also goes to its template and to every other remote
    # button following that template, so the AutoProgrammer has nothing to undo.
    def assign(target, zone_href, level = 100, fade = 2, delay = 0)
      tmpl = target.start_with?('/button/') ? linked_template(target) : nil
      done = assign_one(target, zone_href, level, fade, delay)
      follow_template(target, tmpl, done) { |t| assign_one(t, zone_href, level, fade, delay) }
    end

    def unassign(target, zone_href)
      tmpl = target.start_with?('/button/') ? linked_template(target) : nil
      done = unassign_one(target, zone_href)
      return done if done.empty?
      [follow_template(target, tmpl, done.join(', ')) { |t| unassign_one(t, zone_href).empty? ? 'nothing to remove' : 'removed' }]
    end

    def assign_one(target, zone_href, level = 100, fade = 2, delay = 0)
      if (dev = column_device(target))
        g = column_group(dev)
        return 'already there' if (g['AffectedZones'] || []).any? { |z| z.dig('Zone', 'href') == zone_href }
        write!('CreateRequest', "#{g['href']}/affectedzone", { AffectedZone: { Zone: { href: zone_href } } })
        return "added to #{device_label(dev)} (all buttons)"
      end
      preset = presets_of(target).first or raise Error, "#{target} has no programmable preset"
      existing = assignments(preset).find { |a| a.dig('AffectedZone', 'href') == zone_href }
      num = ->(x) { x.to_s.include?('.') ? Float(x) : Integer(x) } # the bridge stores whole seconds as integers
      body = { PresetAssignment: { Level: Integer(level), Fade: num.call(fade), Delay: num.call(delay) } }
      if existing
        write!('UpdateRequest', existing['href'], body)
        "updated #{existing['href']}"
      else
        body[:PresetAssignment][:AffectedZone] = { href: zone_href }
        "created #{write!('CreateRequest', "#{preset}/presetassignment", body)['PresetAssignment']['href']}"
      end
    end

    def unassign_one(target, zone_href)
      if (dev = column_device(target))
        az = (column_group(dev)['AffectedZones'] || []).find { |z| z.dig('Zone', 'href') == zone_href } or return []
        write!('DeleteRequest', az['href'])
        return ["#{device_label(dev)} (all buttons)"]
      end
      presets_of(target).flat_map { |p| assignments(p) }.select { |a| a.dig('AffectedZone', 'href') == zone_href }.map do |a|
        write!('DeleteRequest', a['href'])
        target
      end
    end

    # Takes a light out of everything that programs it: buttons, Column Picos, schedules, scenes, templates.
    def unassign_everywhere(zone_href)
      targets = button_devices.flat_map { |d| column_group(d) ? [d['href']] : device_programming(d).map { |b| b[:button] } }
      targets += schedule_events.map { |e| e['href'] } + virtual_buttons.map { |v| v['href'] }
      targets.flat_map { |t| unassign_one(t, zone_href).map { |x| x.start_with?('/button') ? button_label(x) : x } }
    end

    # Clears a button and, on an engraved remote, its template and every remote button sharing it, so
    # the AutoProgrammer has nothing to copy back. Returns a description of what was cleared.
    def clear_button(button_href)
      tmpl = button_href.start_with?('/button/') ? linked_template(button_href) : nil
      clear = lambda do |t|
        n = presets_of(t).flat_map { |p| assignments(p) }.each { |a| write!('DeleteRequest', a['href']) }.size
        n.zero? ? 'already empty' : "cleared #{n} #{n == 1 ? 'action' : 'actions'}"
      end
      follow_template(button_href, tmpl, "#{button_label(button_href)}: #{clear.call(button_href)}") { |t| clear.call(t) }
    end

    def button_label(button_href)
      dev = button_devices.find { |d| device_programming(d).any? { |b| b[:button] == button_href } }
      btn = read(button_href)['Button']
      dev ? "#{device_label(dev)} #{btn['Name']}" : button_href
    end

    # Removes a device from the system (the app's "Delete device").
    def remove_device(href)
      write!('DeleteRequest', href)
    end

    # ---- schedules -----------------------------------------------------------------------------

    def parse_days(spec)
      on = case spec.to_s.downcase
           when 'daily' then DAYS
           when 'weekdays' then DAYS[1..5]
           when 'weekends' then %w[Sunday Saturday]
           else spec.to_s.split(',').map { |d| DAYS.find { |x| x.downcase.start_with?(d.strip.downcase[0, 3]) } or raise Error, "day #{d.inspect}?" }
           end
      raise Error, 'a schedule needs at least one day' if on.empty?
      DAYS.to_h { |d| [d, on.include?(d)] }.merge('ScheduleType' => 'DayOfWeek')
    end

    def parse_time(spec)
      case spec.to_s.downcase.delete(' ')
      when /\A(\d{1,2}):(\d{2})\z/ then { 'TimeclockEventType' => 'FixedTime', 'TimeOfDay' => { 'Hour' => $1.to_i, 'Minute' => $2.to_i } }
      when /\A(sunrise|sunset)([+-]\d+)?\z/
        off = $2 ? "#{$2.to_i.negative? ? '-' : ''}#{$2.to_i.abs}:00" : '0'
        { 'TimeclockEventType' => 'Astronomic', 'AstronomicEventType' => $1.capitalize, 'AstronomicTimeOffset' => off }
      else raise Error, "time #{spec.inspect}? (HH:MM, sunrise, sunset-30, sunset+15)"
      end
    end

    def add_schedule(name, days, time)
      body = { 'Name' => name }.merge(parse_days(days)).merge(parse_time(time))
      clock = read('/timeclock')&.dig('Timeclocks', 0, 'href') || '/timeclock/1'
      write!('CreateRequest', "#{clock}/timeclockevent", { TimeclockEvent: body })['TimeclockEvent']['href']
    end

    def update_schedule(href, fields)
      write!('UpdateRequest', href, { TimeclockEvent: fields })
    end

    def enable_schedule(href, on)
      write!('UpdateRequest', "#{href}/status", { TimeclockEventStatus: { EnableState: on ? 'Enabled' : 'Disabled' } })
    end

    def delete_schedule(href)
      write!('DeleteRequest', href)
    end

    # ---- pairing -------------------------------------------------------------------------------

    # Adds devices the way the app does: association mode on, subscribe to /device/status/deviceheard;
    # when a device asks to join (someone holds its button until it flashes rapidly) create it with
    # CreateRequest /device (the heard details plus Name and AssociatedArea). The bridge does not add heard
    # devices by itself and only accepts devices heard in the current session. Then Lutron's
    # AutoProgrammer programs the new device, creates templates for it and may re-copy templates onto
    # other remotes: auto_program false clears the new device and its new templates and restores
    # everything else to before_backup. Always leaves association mode.
    # Yields progress lines. Returns [new device hrefs, changes to other programming].
    def pair(minutes, auto_program:, before_backup:, area_href:, name: nil, events: nil)
      before = devices.map { |d| d['SerialNumber'] }
      before_templates = templates.map { |v| v['href'] }
      events ||= TlsTransport.new(config.host, config.cert, config.key, ca: config.ca)
      events.send_message('SubscribeRequest', '/device/status/deviceheard', nil, 'heard')
      write!('UpdateRequest', '/system/status', { SystemStatus: { InAssociationMode: true } })
      found = []
      deadline = Time.now + minutes * 60
      begin
        while Time.now < deadline
          msg = events.next_message([deadline - Time.now, 1].min) or next
          heard = msg.dig('Body', 'DeviceStatus', 'DeviceHeard')
          next unless heard && heard['SerialNumber'] && !heard['ErrorCode'] && !before.include?(heard['SerialNumber'])
          next if found.any? { |h| device(h)&.dig('SerialNumber') == heard['SerialNumber'] }
          label = name ? (found.empty? ? name : "#{name} #{found.size + 1}") : "New #{heard['DeviceType']} #{heard['SerialNumber']}"
          dev = write!('CreateRequest', '/device',
                       { Device: heard.reject { |k, _| k == 'Link' }.merge('Name' => label, 'AssociatedArea' => { 'href' => area_href }) })['Device']
          found << dev['href']
          yield "added #{dev['DeviceType']} #{device_label(dev)} (#{dev['href']}, serial #{dev['SerialNumber']})" if block_given?
          deadline = [deadline, Time.now + 20].min # a little longer for a second device, then stop
        end
      ensure
        write!('UpdateRequest', '/system/status', { SystemStatus: { InAssociationMode: false } })
        events.close
      end
      return [found, []] if found.empty?
      yield "waiting #{@settle} s for the AutoProgrammer" if block_given?
      sleep @settle
      refresh
      unless auto_program
        found.each do |href|
          dev = device(href)
          next unless dev && dev['ButtonGroups']
          if (g = column_group(dev))
            (g['AffectedZones'] || []).each { |z| write!('DeleteRequest', z['href']) }
          else
            device_programming(dev).each { |b| presets_of(b[:button]).flat_map { |p| assignments(p) }.each { |a| write!('DeleteRequest', a['href']) } }
          end
          yield "cleared the AutoProgrammer's programming of #{device_label(dev)}" if block_given?
        end
        (templates.map { |v| v['href'] } - before_templates).each do |t|
          n = presets_of(t).flat_map { |p| assignments(p) }.each { |a| write!('DeleteRequest', a['href']) }.size
          yield "cleared new template #{t} (#{n} lights)" if block_given? && n.positive?
        end
      end
      [found, restore(before_backup, dry_run: auto_program)]
    end

    private

    def follow_template(button_href, tmpl, done)
      case tmpl
      when String
        others = template_buttons(tmpl) - [button_href]
        parts = ["template #{tmpl}: #{yield tmpl}"] + others.map { |b| "shared with #{button_label(b)}: #{yield b}" }
        "#{done}; #{parts.join('; ')}"
      when :unclear then "#{done}; WARNING: can't tell which Lutron template this button follows, so the AutoProgrammer may undo this"
      else done
      end
    end

    def column_device(target)
      dev = device(target) || (target.start_with?('/') ? nil : (find_device(target) rescue nil))
      dev && column_group(dev) ? dev : nil
    end
  end
end
