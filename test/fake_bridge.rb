# frozen_string_literal: true

require 'json'

# An in-memory LEAP bridge for tests: just enough of the RA2 Select model that leapctl uses, with the
# behaviors observed on real hardware (Column Picos derive their buttons from the group's affected
# zones; per-button deletes on them fail with 500; engraved Picos have per-room templates).
class FakeBridge
  TYPES = { 'area' => 'Area', 'device' => 'Device', 'zone' => 'Zone', 'button' => 'Button', 'buttongroup' => 'ButtonGroup',
            'programmingmodel' => 'ProgrammingModel', 'preset' => 'Preset', 'presetassignment' => 'PresetAssignment',
            'vbutton' => 'VirtualButton', 'virtualbutton' => 'VirtualButton', 'timeclockevent' => 'TimeclockEvent' }.freeze
  LISTS = { '/area' => ['Areas', %w[area]], '/device' => ['Devices', %w[device]], '/zone' => ['Zones', %w[zone]],
            '/timeclockevent' => ['TimeclockEvents', %w[timeclockevent]], '/virtualbutton' => ['VirtualButtons', %w[virtualbutton vbutton]] }.freeze

  attr_reader :objects, :commands

  def initialize
    @objects = {}
    @status = {}
    @commands = []
    @next = 1000
    build
  end

  def close; end

  def request(type, url, body = nil)
    send("#{type.sub('Request', '').downcase}_req", url, JSON.parse(JSON.generate(body || {})))
  end

  # ---- the house: Kitchen with a dimmer and an engraved Bedside Pico; Den with a lamp and a Column Pico

  def build
    add('/area/1', 'Name' => 'root')
    add('/area/2', 'Name' => 'Kitchen', 'Parent' => { 'href' => '/area/1' })
    add('/area/3', 'Name' => 'Den', 'Parent' => { 'href' => '/area/1' })
    device('/device/2', 'Main Lights', 'WallDimmer', '/area/2')
    device('/device/3', 'Lamp', 'PlugInDimmer', '/area/3')
    add('/zone/1', 'Name' => 'Main Lights', 'ControlType' => 'Dimmed', 'Device' => { 'href' => '/device/2' })
    add('/zone/2', 'Name' => 'Lamp', 'ControlType' => 'Dimmed', 'Device' => { 'href' => '/device/3' })
    # Column Pico in the Den controlling the lamp
    device('/device/10', 'Pico', 'Pico3ButtonRaiseLower', '/area/3', 'ButtonGroups' => [{ 'href' => '/buttongroup/10' }])
    add('/buttongroup/10', 'Parent' => { 'href' => '/device/10' }, 'ProgrammingType' => 'Column',
                           'AffectedZones' => [], 'Buttons' => [{ 'href' => '/button/100' }])
    button('/button/100', '/buttongroup/10', 0, 100)
    add_affected('/buttongroup/10', '/zone/2')
    # two engraved Bedside Picos in the Kitchen sharing the room's Bedside templates:
    # top button (number 0, Alert) turns Main Lights on; bottom (number 2, GoodNight) is empty
    %w[20 21].each_with_index do |n, i|
      device("/device/#{n}", i.zero? ? 'Bedside' : 'Bedside 2', 'Pico2Button', '/area/2', 'EngravingKit' => 'Bedside', 'ButtonGroups' => [{ 'href' => "/buttongroup/#{n}" }])
      add("/buttongroup/#{n}", 'Parent' => { 'href' => "/device/#{n}" }, 'ProgrammingType' => 'Freeform',
                               'Buttons' => [{ 'href' => "/button/#{n}0" }, { 'href' => "/button/#{n}1" }])
      button("/button/#{n}0", "/buttongroup/#{n}", 0, "#{n}0".to_i)
      button("/button/#{n}1", "/buttongroup/#{n}", 2, "#{n}1".to_i)
      assignment("/preset/#{n}0", '/zone/1', 100)
    end
    template('/vbutton/1', '/area/2', 'Bedside', 'Alert', 0, 301)
    template('/vbutton/2', '/area/2', 'Bedside', 'GoodNight', 2, 302)
    assignment('/preset/301', '/zone/1', 100)
    add('/virtualbutton/1', 'Name' => 'Arriving Home', 'ProgrammingModel' => { 'href' => '/programmingmodel/500' })
    add('/programmingmodel/500', 'ProgrammingModelType' => 'SingleActionProgrammingModel', 'Preset' => { 'href' => '/preset/500' })
    add('/timeclock/1', {})
  end

  def add(href, obj)
    @objects[href] = obj.merge('href' => href)
  end

  def device(href, name, type, area, extra = {})
    add(href, { 'Name' => name, 'DeviceType' => type, 'SerialNumber' => href.split('/').last.to_i * 1111,
                'AssociatedArea' => { 'href' => area }, 'FullyQualifiedName' => [@objects[area]['Name'], name] }.merge(extra))
  end

  # number: the button's position (Pico2Button: 0 top, 2 bottom); pm: numbering of its model/preset
  def button(href, group, number, pm)
    add(href, 'Name' => "Button #{number + 1}", 'ButtonNumber' => number, 'Parent' => { 'href' => group },
              'ProgrammingModel' => { 'href' => "/programmingmodel/#{pm}" })
    add("/programmingmodel/#{pm}", 'ProgrammingModelType' => 'SingleActionProgrammingModel', 'Preset' => { 'href' => "/preset/#{pm}" })
  end

  def template(href, area, type, sub, number, n)
    add(href, 'Parent' => { 'href' => area }, 'Category' => { 'Type' => type, 'SubType' => sub }, 'ButtonNumber' => number,
              'ProgrammingModel' => { 'href' => "/programmingmodel/#{n}" })
    add("/programmingmodel/#{n}", 'ProgrammingModelType' => 'SingleActionProgrammingModel', 'Preset' => { 'href' => "/preset/#{n}" })
  end

  def assignment(preset, zone, level, fade = 2, delay = 0)
    href = "/presetassignment/#{@next += 1}"
    add(href, 'Parent' => { 'href' => preset }, 'AffectedZone' => { 'href' => zone }, 'Level' => level, 'Fade' => fade, 'Delay' => delay)
  end

  def add_affected(group, zone)
    @objects[group]['AffectedZones'] << { 'href' => "#{group}/affectedzone/#{zone.split('/').last}", 'Zone' => { 'href' => zone } }
    derive(group)
  end

  # Column groups: every button's preset holds the group's zones (Lutron derives them).
  def derive(group)
    zones = @objects[group]['AffectedZones'].map { |z| z.dig('Zone', 'href') }
    @objects[group]['Buttons'].each do |b|
      preset = preset_of_button(b['href'])
      @objects.delete_if { |_, o| o.dig('Parent', 'href') == preset && o.key?('AffectedZone') }
      zones.each { |z| assignment(preset, z, 100) }
    end
  end

  def preset_of_button(button)
    @objects[@objects[button].dig('ProgrammingModel', 'href')].dig('Preset', 'href')
  end

  def column_assignment?(href)
    preset = @objects[href]&.dig('Parent', 'href')
    @objects.values.any? { |g| g['ProgrammingType'] == 'Column' && g['Buttons'].any? { |b| preset_of_button(b['href']) == preset } }
  end

  # ---- requests -------------------------------------------------------------------------------------

  def ok(code, body)
    { 'Header' => { 'StatusCode' => code }, 'Body' => body }
  end

  def failure(code, msg)
    { 'Header' => { 'StatusCode' => code }, 'Body' => { 'Message' => msg } }
  end

  def read_req(url, _body)
    if (list = LISTS[url])
      items = @objects.select { |h, _| list[1].any? { |t| h.start_with?("/#{t}/") } && h.count('/') == 2 }.values
      return ok('200 OK', list[0] => items)
    end
    return ok('200 OK', 'Timeclocks' => [{ 'href' => '/timeclock/1' }]) if url == '/timeclock'
    if url =~ %r{\A(/preset/\d+)/presetassignment\z}
      items = @objects.values.select { |o| o.dig('Parent', 'href') == $1 && o.key?('AffectedZone') }
      return items.empty? ? ok('204 NoContent', nil) : ok('200 OK', 'PresetAssignments' => items)
    end
    if url =~ %r{\A(/timeclockevent/\d+)/status\z} && @objects[$1]
      return ok('200 OK', 'TimeclockEventStatus' => { 'TimeclockEvent' => { 'href' => $1 }, 'EnableState' => @status[$1] || 'Enabled' })
    end
    obj = @objects[url] or return failure('404 NotFound', "This resource does not exist : #{url}")
    if url.start_with?('/area/') # the real bridge lists a room's devices
      obj = obj.merge('AssociatedDevices' => @objects.values.select { |o| o.dig('AssociatedArea', 'href') == url }.map { |o| { 'href' => o['href'] } })
    end
    ok('200 OK', TYPES.fetch(url.split('/')[1], 'Object') => obj)
  end

  def create_req(url, body)
    case url
    when %r{\A(/preset/\d+)/presetassignment\z}
      pa = body['PresetAssignment']
      ok('201 Created', 'PresetAssignment' => assignment($1, pa.dig('AffectedZone', 'href'), pa['Level'], pa['Fade'], pa['Delay']))
    when %r{\A(/buttongroup/\d+)/affectedzone\z}
      add_affected($1, body.dig('AffectedZone', 'Zone', 'href'))
      ok('201 Created', 'AffectedZone' => @objects[$1]['AffectedZones'].last)
    when '/timeclock/1/timeclockevent'
      ev = body['TimeclockEvent']
      return failure('400 BadRequest', 'Must specify at least one day of the week for a DayOfWeek event.') unless %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday].any? { |d| ev[d] }
      n = @next += 1
      add("/programmingmodel/#{n}", 'ProgrammingModelType' => 'SingleActionProgrammingModel', 'Preset' => { 'href' => "/preset/#{n}" })
      ok('201 Created', 'TimeclockEvent' => add("/timeclockevent/#{n}", ev.merge('ProgrammingModel' => { 'href' => "/programmingmodel/#{n}" })))
    when '/area'
      ok('201 Created', 'Area' => add("/area/#{@next += 1}", body['Area']))
    when %r{/commandprocessor\z}
      @commands << [url, body]
      ok('201 Created', nil)
    else failure('400 BadRequest', 'This request is not supported')
    end
  end

  def update_req(url, body)
    if url =~ %r{\A(/timeclockevent/\d+)/status\z}
      @status[$1] = body.dig('TimeclockEventStatus', 'EnableState')
      return ok('200 OK', body)
    end
    obj = @objects[url] or return failure('404 NotFound', 'This resource does not exist')
    obj.merge!(body.values.first)
    if url.start_with?('/device/')
      obj['FullyQualifiedName'] = [@objects[obj.dig('AssociatedArea', 'href')]['Name'], obj['Name']]
    end
    ok('200 OK', TYPES.fetch(url.split('/')[1], 'Object') => obj)
  end

  def delete_req(url, _body)
    if url =~ %r{\A(/buttongroup/\d+)/affectedzone/\d+\z}
      group = @objects[$1]
      group['AffectedZones'].reject! { |z| z['href'] == url }
      derive($1)
      return ok('204 NoContent', nil)
    end
    return failure('500 InternalServerError', 'An unknown error occurred') if column_assignment?(url)
    @objects.delete(url) or return failure('404 NotFound', 'This resource does not exist')
    ok('204 NoContent', nil)
  end
end
