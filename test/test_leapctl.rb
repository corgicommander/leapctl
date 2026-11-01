# frozen_string_literal: true

# Offline tests against FakeBridge: ruby test/test_leapctl.rb
require 'minitest/autorun'
require 'tmpdir'
require 'stringio'
require_relative '../lib/leapctl'
require_relative 'fake_bridge'

class LeapctlTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @bridge = FakeBridge.new
    @config = Leapctl::Config.new('host' => 'fake', 'backup_dir' => @dir)
    @c = Leapctl::Client.new(@config, transport: @bridge, settle: 0)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def zones_of(target)
    @c.refresh
    @c.action_set(target).map(&:first)
  end

  def test_names_resolve_and_errors_are_clear
    assert_equal '/zone/2', @c.find_zone('Den / Lamp')
    assert_equal '/zone/2', @c.find_zone('lamp')
    assert_equal '/area/2', @c.find_area('Kitchen')
    err = assert_raises(Leapctl::Error) { @c.find_zone('nothing like this') }
    assert_match(/not found/, err.message)
  end

  def test_column_pico_is_edited_through_its_group
    assert_equal ['/zone/2'], zones_of('/button/100')
    assert_match(/all buttons/, @c.assign('/device/10', '/zone/1'))
    assert_equal ['/zone/1', '/zone/2'], zones_of('/button/100').sort
    @c.unassign('/device/10', '/zone/2')
    assert_equal ['/zone/1'], zones_of('/button/100')
  end

  def test_engraved_button_edit_also_changes_its_template
    assert_equal '/vbutton/1', @c.linked_template('/button/200')
    result = @c.assign('/button/200', '/zone/2', 40)
    assert_match(%r{template /vbutton/1}, result)
    assert_equal ['/zone/1', '/zone/2'], zones_of('/button/200').sort
    assert_equal ['/zone/1', '/zone/2'], zones_of('/vbutton/1').sort
    assert_empty @c.template_drift
    @c.unassign('/button/200', '/zone/2')
    assert_equal ['/zone/1'], zones_of('/vbutton/1')
  end

  def test_clear_button_clears_the_template_too
    @c.clear_button('/button/200')
    assert_empty zones_of('/button/200')
    assert_empty zones_of('/vbutton/1')
    assert_empty zones_of('/button/210') # the other remote sharing the template
  end

  def test_shared_template_keeps_both_remotes_in_step
    assert_equal ['/button/200', '/button/210'], @c.template_buttons('/vbutton/1')
    result = @c.assign('/button/200', '/zone/2', 40)
    assert_match(%r{shared with Kitchen / Bedside 2 Button 1}, result)
    assert_equal ['/zone/1', '/zone/2'], zones_of('/button/210').sort
    assert_empty @c.template_drift
  end

  def test_empty_buttons_still_find_their_template_by_number
    assert_equal '/vbutton/2', @c.linked_template('/button/201') # both empty templates, told apart by ButtonNumber
  end

  def test_drift_is_reported_when_only_the_button_changes
    @c.assign_one('/button/200', '/zone/2', 40)
    @c.refresh
    assert_equal ['Kitchen / Bedside Button 1'], @c.template_drift
  end

  def test_restore_undoes_every_kind_of_change
    before = @c.backup
    @c.assign('/device/10', '/zone/1')
    @c.assign('/button/200', '/zone/2', 40)
    @c.assign('/button/201', '/zone/1', 0)
    @c.refresh
    changes = @c.restore(before, dry_run: true)
    assert_equal 7, changes.size, changes.inspect # Column Pico; 2 buttons on each Bedside remote; 2 templates
    @c.restore(before, dry_run: false)
    @c.refresh
    assert_empty @c.restore(before, dry_run: true)
  end

  def test_schedule_lifecycle
    ev = @c.add_schedule('Porch', 'weekdays', 'sunset-30')
    @c.refresh
    e = @c.read(ev)['TimeclockEvent']
    assert_equal 'Astronomic', e['TimeclockEventType']
    assert_equal '-30:00', e['AstronomicTimeOffset']
    assert_equal 'sunset -30 min', @c.describe_time(e)
    assert_equal 'weekdays', @c.describe_days(e)
    @c.enable_schedule(ev, false)
    @c.refresh
    assert_equal 'Disabled', @c.schedule_status(ev)
    @c.assign(ev, '/zone/1', 80)
    assert_equal ['/zone/1'], zones_of(ev)
    @c.delete_schedule(ev)
    @c.refresh
    assert_empty @c.schedule_events
  end

  def test_time_and_day_parsing
    assert_equal({ 'Hour' => 7, 'Minute' => 5 }, @c.parse_time('07:05')['TimeOfDay'])
    assert_equal '15:00', @c.parse_time('sunrise+15')['AstronomicTimeOffset']
    assert_equal '0', @c.parse_time('sunset')['AstronomicTimeOffset']
    days = @c.parse_days('Mon,wed')
    assert days['Monday'] && days['Wednesday'] && !days['Sunday']
    assert_raises(Leapctl::Error) { @c.parse_time('noon') }
    assert_raises(Leapctl::Error) { @c.parse_days('someday') }
  end

  def test_unassign_everywhere_reaches_buttons_columns_and_templates
    @c.assign('/device/10', '/zone/1')
    done = @c.unassign_everywhere('/zone/1')
    assert_equal 4, done.size, done.inspect # Column Pico, both Bedside top buttons, template /vbutton/1
    assert_empty zones_of('/button/200')
    assert_empty zones_of('/vbutton/1')
  end

  def test_rooms_and_moves
    room = @c.add_area('Office')
    @c.refresh
    assert_equal 'Office', @c.area_name(room)
    before = @c.backup
    assert_empty @c.move_device('/device/3', room, auto_program: false, before_backup: before)
    @c.refresh
    assert_equal 'Office / Lamp', @c.device_label(@c.device('/device/3'))
    assert_raises(Leapctl::Error) { @c.delete_area('/area/3') } # still has the Pico
  end

  def test_commands_take_a_backup_before_changes
    lines = Leapctl::Commands.call(@c, 'assign', 'target' => '/button/201', 'zone' => 'Lamp', 'level' => 30)
    assert_match(/\Abackup: /, lines.first)
    assert_equal 1, @c.backups.size
    assert_match(/no differences|remove/, Leapctl::Commands.call(@c, 'diff', {}).join)
  end

  def test_cli_refuses_changes_without_yes
    out = StringIO.new
    err = assert_raises(SystemExit) do
      capture_io { Leapctl::CLI.run(%w[assign /button/201 Lamp --host=fake --cert=x --key=y], out: out) }
    end
    assert_equal 1, err.status
  end

  def test_mcp_lists_tools_and_requires_confirm
    input = StringIO.new([
      { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18' } },
      { jsonrpc: '2.0', id: 2, method: 'tools/list' },
      { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'lutron_assign', arguments: { target: '/button/201', zone: 'Lamp' } } },
      { jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'lutron_assign', arguments: { target: '/button/201', zone: 'Lamp', confirm: true } } },
      { jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'lutron_programming', arguments: { device: 'Bedside' } } }
    ].map(&:to_json).join("\n") + "\n")
    output = StringIO.new
    capture_io { Leapctl::MCP.new(@config, input: input, output: output, client: -> { @c }).run }
    replies = output.string.lines.map { |l| JSON.parse(l) }.to_h { |r| [r['id'], r] }
    assert_equal '2025-06-18', replies[1].dig('result', 'protocolVersion')
    names = replies[2].dig('result', 'tools').map { |t| t['name'] }
    assert_includes names, 'lutron_pair'
    pair = replies[2].dig('result', 'tools').find { |t| t['name'] == 'lutron_pair' }
    assert_includes pair.dig('inputSchema', 'required'), 'auto_program'
    assert replies[3].dig('result', 'isError')
    refute replies[4].dig('result', 'isError')
    assert_match(/Lamp → 100/, replies[5].dig('result', 'content', 0, 'text'))
  end
end
