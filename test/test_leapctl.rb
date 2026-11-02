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

  # ---- 0.1.1 --------------------------------------------------------------------------------------

  # The bridge lists actions in no fixed order and renumbers an assignment whenever Lutron re-creates it.
  def test_snapshot_and_diff_ignore_reordered_and_renumbered_assignments
    @c.assign_one('/button/200', '/zone/2', 40)
    @c.refresh
    before = @c.backup
    first = JSON.parse(File.read(before)).reject { |k, _| k == 'taken_at' }
    old = @bridge.objects.values.find { |o| o.dig('Parent', 'href') == '/preset/200' && o.dig('AffectedZone', 'href') == '/zone/1' }
    @bridge.objects.delete(old['href'])
    @bridge.assignment('/preset/200', '/zone/1', old['Level'], old['Fade'], old['Delay']) # new href, now listed last
    @c.refresh
    refute_equal ['/zone/1', '/zone/2'], @c.device_programming(@c.device('/device/20')).first[:actions].map { |a| a[:zone] }
    assert_equal first, JSON.parse(JSON.generate(@c.snapshot)).reject { |k, _| k == 'taken_at' }
    assert_empty @c.restore(before, dry_run: true)
    refute_match(/presetassignment/, JSON.generate(first['programming']))
  end

  def self_signed(key, name)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{name}")
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert.sign(key, OpenSSL::Digest::SHA256.new)
    cert
  end

  def cert_pair(dir, prefix)
    @@pair ||= begin
      key = OpenSSL::PKey::RSA.new(2048)
      [self_signed(key, 'pylutron_caseta').to_pem, key.to_pem]
    end
    File.write(File.join(dir, "#{prefix}-cert.pem"), @@pair[0])
    File.write(File.join(dir, "#{prefix}-key.pem"), @@pair[1])
    [File.join(dir, "#{prefix}-cert.pem"), File.join(dir, "#{prefix}-key.pem")]
  end

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def test_home_assistant_certificate_and_address_come_from_its_config_entry
    ha = File.join(@dir, 'ha')
    FileUtils.mkdir_p(File.join(ha, '.storage'))
    cert, key = cert_pair(ha, 'lutron_caseta-0386dd5d') # HA found the bridge by itself: files named after Lutron's ID
    entries = [{ 'domain' => 'met', 'data' => { 'api_key' => 'not ours' } },
               { 'domain' => 'lutron_caseta', 'data' => { 'host' => '192.168.1.20', 'keyfile' => File.basename(key),
                                                          'certfile' => File.basename(cert), 'ca_certs' => 'x-ca.pem' } }]
    File.write(File.join(ha, '.storage', 'core.config_entries'), JSON.generate('version' => 1, 'data' => { 'entries' => entries }))
    assert_equal [{ 'host' => '192.168.1.20', 'cert' => cert, 'key' => key }], Leapctl::CertFinder.home_assistant(ha)
    File.delete(File.join(ha, '.storage', 'core.config_entries')) # only the files: the name holds the ID, not an address
    assert_equal [{ 'cert' => cert, 'key' => key, 'lutron_id' => '0386dd5d' }], Leapctl::CertFinder.home_assistant(ha)
    unknown = ->(_id) { nil } # lutron-<id>.local didn't resolve
    err = assert_raises(Leapctl::Error) { Leapctl::Setup.settings({ 'from_home_assistant' => ha }, resolver: unknown) }
    assert_match(/--host=/, err.message)
    assert_equal '192.168.1.20', Leapctl::Setup.settings({ 'from_home_assistant' => ha, 'host' => '192.168.1.20' }, resolver: unknown)['host']
    assert_equal '10.0.0.7', Leapctl::Setup.settings({ 'from_home_assistant' => ha }, resolver: ->(id) { '10.0.0.7' if id == '0386dd5d' })['host']
  end

  def test_setup_checks_the_files_and_connects_before_saving
    cert, key = cert_pair(@dir, 'client')
    File.write(other = File.join(@dir, 'other-key.pem'), OpenSSL::PKey::RSA.new(1024).to_pem)
    File.write(empty = File.join(@dir, 'empty.pem'), '')
    with_env('LEAPCTL_CONFIG' => File.join(@dir, 'config.json'), 'LEAP_HOST' => nil, 'LEAP_CERT' => nil, 'LEAP_KEY' => nil) do
      fake = ->(config) { Leapctl::Client.new(config, transport: FakeBridge.new, settle: 0) }
      { [empty, key] => /isn't a PEM certificate \(the file is empty\)/, [key, cert] => /swapped/, [cert, other] => /doesn't belong/ }.each do |(c, k), msg|
        err = assert_raises(Leapctl::Error) { Leapctl::Setup.run({ 'host' => '192.168.1.20', 'cert' => c, 'key' => k }, connect: fake) }
        assert_match msg, err.message
      end
      refute File.exist?(File.join(@dir, 'config.json'))
      broken = ->(_config) { raise Leapctl::Error, "can't connect to the bridge" }
      assert_raises(Leapctl::Error) { Leapctl::Setup.run({ 'host' => '192.168.1.20', 'cert' => cert, 'key' => key }, connect: broken) }
      refute File.exist?(File.join(@dir, 'config.json'))
      lines = Leapctl::Setup.run({ 'host' => '192.168.1.20', 'cert' => cert, 'key' => key }, connect: fake)
      assert_match(/\Asaved /, lines.first)
      assert_equal({ 'host' => '192.168.1.20', 'cert' => cert, 'key' => key }, JSON.parse(File.read(File.join(@dir, 'config.json'))))
    end
  end

  def test_cli_refuses_unknown_options_and_extra_words
    { %w[assign /button/201 Lamp --levle=50 --yes] => /unknown option --levle/,
      %w[rename-device Lamp Desk Lamp --yes] => /too many arguments/,
      %w[assign /button/201 Lamp --level --yes] => /--level needs a value/ }.each do |argv, msg|
      _, err = capture_io { assert_raises(SystemExit) { Leapctl::CLI.run(argv + %w[--host=fake --cert=x --key=y], out: StringIO.new) } }
      assert_match msg, err
    end
  end

  def test_cli_help_and_version
    out = StringIO.new
    Leapctl::CLI.run(['--version'], out: out)
    Leapctl::CLI.run(%w[assign --help], out: out)
    Leapctl::CLI.run(%w[help setup], out: out)
    Leapctl::CLI.run(['-h'], out: out)
    assert_match(/\Aleapctl #{Leapctl::VERSION}\n/, out.string)
    assert_match(/leapctl assign <target> <zone>/, out.string)
    assert_match(/leapctl setup --from-home-assistant/, out.string)
    assert_match(/^Change \(--yes/, out.string)
  end

  def test_blank_environment_variables_count_as_unset
    with_env('LEAPCTL_CONFIG' => ' ', 'XDG_CONFIG_HOME' => '') do
      assert_equal File.join(Dir.home, '.config', 'leapctl', 'config.json'), Leapctl::Config.path
    end
  end

  def test_backups_need_no_bridge_and_empty_output_says_none
    with_env('LEAPCTL_CONFIG' => File.join(@dir, 'none.json'), 'LEAP_HOST' => nil, 'LEAP_CERT' => nil, 'LEAP_KEY' => nil) do
      out = StringIO.new
      Leapctl::CLI.run(['backups', "--backup-dir=#{@dir}"], out: out)
      assert_equal "(none)\n", out.string
    end
  end

  def mcp(*messages)
    input = StringIO.new(messages.map(&:to_json).join("\n") + "\n")
    output = StringIO.new
    capture_io { Leapctl::MCP.new(@config, input: input, output: output, client: -> { @c }).run }
    output.string.lines.map { |l| JSON.parse(l) }.to_h { |r| [r['id'], r] }
  end

  def test_mcp_annotations_unknown_tools_setup_and_empty_results
    replies = mcp({ jsonrpc: '2.0', id: 1, method: 'tools/list' },
                  { jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'lutron_nothing', arguments: {} } },
                  { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'lutron_setup', arguments: { home_assistant: '/config' } } },
                  { jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'lutron_schedules', arguments: {} } })
    tools = replies[1].dig('result', 'tools').to_h { |t| [t['name'], t] }
    assert tools['lutron_programming'].dig('annotations', 'readOnlyHint')
    assert tools['lutron_assign'].dig('annotations', 'destructiveHint')
    refute tools['lutron_level'].dig('annotations', 'destructiveHint')
    assert_equal 'Lutron clear button', tools['lutron_clear_button'].dig('annotations', 'title')
    assert_includes tools['lutron_setup'].dig('inputSchema', 'required'), 'confirm'
    # every change tool, and setup, needs a person's approval in Claude Code; reads and control don't
    flagged = tools.values.select { |t| t.dig('_meta', 'anthropic/requiresUserInteraction') == true }.map { |t| t['name'] }
    changes = Leapctl::Commands::REGISTRY.values.select { |c| c.kind == :change }.map { |c| "lutron_#{c.name.tr('-', '_')}" }
    assert_equal (changes + ['lutron_setup']).sort, flagged.sort
    assert_equal(-32_602, replies[2].dig('error', 'code'))
    assert replies[3].dig('result', 'isError')
    assert_equal '(none)', replies[4].dig('result', 'content', 0, 'text')
  end

  def test_changes_say_what_home_assistant_needs
    lines = Leapctl::Commands.call(@c, 'rename-device', 'device' => 'Lamp', 'name' => 'Desk_Lamp')
    assert_includes lines, Leapctl::Commands::HA_NAMES
    assert_includes lines, Leapctl::Commands::HA_UNDERSCORE
    assert_includes Leapctl::Commands.call(@c, 'rename-zone', 'zone' => 'Main Lights', 'name' => 'Ceiling'), Leapctl::Commands::HA_ZONE
    lines = Leapctl::Commands.call(@c, 'remove-device', 'device' => 'Bedside 2')
    assert_equal ['removed Kitchen / Bedside 2', Leapctl::Commands::HA_REMOVED], lines.drop(1)
    refute_includes Leapctl::Commands.call(@c, 'assign', 'target' => '/button/201', 'zone' => 'Lamp'), Leapctl::Commands::HA_NAMES
  end

  # Claude starts the server without a language setting (LANG), so stdin isn't marked as UTF-8.
  def test_mcp_reads_accented_names_without_a_language_setting
    line = { jsonrpc: '2.0', id: 7, method: 'tools/call',
             params: { name: 'lutron_rename_zone', arguments: { zone: 'Lamp', name: 'Lampe du café', confirm: true } } }.to_json
    output = StringIO.new
    capture_io { Leapctl::MCP.new(@config, input: StringIO.new((line + "\n").b.force_encoding('US-ASCII')), output: output, client: -> { @c }).run }
    reply = JSON.parse(output.string.lines.first)
    refute reply.dig('result', 'isError'), reply.inspect
    assert_equal 'Lampe du café', @bridge.objects['/zone/2']['Name']
  end

  # ---- found in the 0.1.1 review --------------------------------------------------------------------

  def test_diff_and_restore_read_only_leapctl_backups
    before = @c.backup
    assert_empty @c.restore(File.basename(before), dry_run: true) # a name as `backups` lists it
    File.write(key = File.join(Dir.mktmpdir, 'secret-key.pem'), "-----BEGIN RSA PRIVATE KEY-----\nsecret\n")
    err = assert_raises(Leapctl::Error) { @c.restore(key, dry_run: true) }
    assert_match(/no backup/, err.message)
    File.write(junk = File.join(@dir, 'junk.json'), "secret: not json\n")
    err = assert_raises(Leapctl::Error) { @c.restore('junk.json', dry_run: true) }
    assert_equal "junk.json isn't a leapctl backup", err.message
    refute_match(/secret/, err.message)
    count = @c.backups.size
    assert_raises(Leapctl::Error) { Leapctl::Commands.call(@c, 'restore', 'backup' => 'nonexistent.json') }
    assert_equal count, @c.backups.size # refused before taking its own backup
    assert_equal 0o600, File.stat(before).mode & 0o777
  ensure
    FileUtils.rm_rf(File.dirname(key)) if key
  end

  def test_backups_leave_out_the_network_key
    snap = JSON.generate(@c.snapshot)
    refute_match(/NetworkMasterKey|not-for-backups/, snap)
    assert_match(/ClearConnectTypeX/, snap)
  end

  def cli_error(*argv)
    _, err = capture_io { assert_raises(SystemExit) { Leapctl::CLI.run(argv + %w[--host=fake --cert=x --key=y], out: StringIO.new) } }
    err
  end

  def test_cli_switches_take_no_values_and_dashes_are_options
    assert_match(/--auto-program takes no value/, cli_error('pair', 'Kitchen', '--auto-program=false', '--yes'))
    assert_match(/--yes takes no value/, cli_error('clear-button', '/button/201', '--yes=no'))
    assert_match(/add --no-auto-program .* or --auto-program/, cli_error('pair', 'Kitchen', '--yes'))
    assert_match(/unknown option --Name .*--name=/, cli_error('rename-zone', 'Lamp', '--Name=Desk Lamp', '--yes'))
    assert_match(/did you mean --yes/, cli_error('clear-button', '/button/201', '-y'))
    assert_match(/did you mean --from-home-assistant=\/Volumes\/config/, cli_error('setup', '/Volumes/config'))
  end

  def test_setup_says_when_the_environment_hides_what_it_saved
    cert, key = cert_pair(@dir, 'client')
    with_env('LEAPCTL_CONFIG' => File.join(@dir, 'config.json'), 'LEAP_HOST' => '10.0.0.1', 'LEAP_CERT' => nil, 'LEAP_KEY' => nil) do
      File.write(File.join(@dir, 'config.json'), '{"host": "192.168.1.9",}') # broken by hand
      fake = ->(config) { Leapctl::Client.new(config, transport: FakeBridge.new, settle: 0) }
      lines = Leapctl::Setup.run({ 'host' => '192.168.1.20', 'cert' => cert, 'key' => key }, connect: fake)
      assert_match(/note: LEAP_HOST is set .* overrides the saved host/, lines.join("\n"))
      assert_equal '192.168.1.20', JSON.parse(File.read(File.join(@dir, 'config.json')))['host']
      assert File.exist?(File.join(@dir, 'config.json.bak'))
    end
  end

  def test_certificate_mistakes_are_named
    cert, key = cert_pair(@dir, 'lutron_caseta-h')
    File.write(ca = File.join(@dir, 'lutron_caseta-h-ca.pem'), self_signed(OpenSSL::PKey::RSA.new(1024), 'ca').to_pem)
    err = assert_raises(Leapctl::Error) { Leapctl::Setup.check_files(cert, ca) }
    assert_match(/is a certificate, not a private key/, err.message)
    err = assert_raises(Leapctl::Error) { Leapctl::TlsTransport.context(ca, key) } # outside setup too, before connecting
    assert_match(/doesn't belong .*not -ca\.pem/, err.message)
    File.write(locked = File.join(@dir, 'locked-key.pem'), OpenSSL::PKey::RSA.new(1024).export(OpenSSL::Cipher.new('aes-128-cbc'), 'pw'))
    err = assert_raises(Leapctl::Error) { Leapctl::TlsTransport.context(cert, locked) }
    assert_match(/passphrase/, err.message)
  end

  # A local TLS server stands in for the bridge.
  def test_the_bridge_certificate_is_checked_when_its_ca_is_known
    cert, key = cert_pair(@dir, 'client')
    bridge_key = OpenSSL::PKey::RSA.new(2048)
    bridge_cert = self_signed(bridge_key, 'SmartBridge')
    File.write(ca = File.join(@dir, 'bridge-ca.pem'), bridge_cert.to_pem)
    File.write(other = File.join(@dir, 'other-ca.pem'), self_signed(OpenSSL::PKey::RSA.new(1024), 'Other').to_pem)
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.cert = bridge_cert
    ctx.key = bridge_key
    tcp = TCPServer.new('127.0.0.1', 0)
    server = OpenSSL::SSL::SSLServer.new(tcp, ctx)
    thread = Thread.new { loop { (server.accept.close rescue nil) } }
    port = tcp.addr[1]
    Leapctl::TlsTransport.new('127.0.0.1', cert, key, ca: ca, port: port).close
    File.binwrite(der = File.join(@dir, 'bridge-ca.der'), bridge_cert.to_der)
    Leapctl::TlsTransport.new('127.0.0.1', cert, key, ca: der, port: port).close # a DER file works too
    Leapctl::TlsTransport.new('127.0.0.1', cert, key, port: port).close # no CA known: not checked
    err = assert_raises(Leapctl::Error) { Leapctl::TlsTransport.new('127.0.0.1', cert, key, ca: other, port: port) }
    assert_match(/isn't the bridge other-ca\.pem belongs to/, err.message)
  ensure
    thread&.kill
    server&.close
  end

  def test_mcp_survives_odd_messages
    lines = ["\xFF{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}   ", # a stray byte: answered, not fatal
             '[{"jsonrpc":"2.0","id":2,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]',
             '"just a string"',
             '{"jsonrpc":"2.0","method":"tools/list"}', # a notification: no answer
             '{"jsonrpc":"2.0","id":5,"method":"ping"}']
    output = StringIO.new
    capture_io { Leapctl::MCP.new(@config, input: StringIO.new(lines.join("\n").b + "\n"), output: output, client: -> { @c }).run }
    replies = output.string.lines.map { |l| JSON.parse(l) }
    assert_equal(-32_700, replies[0].dig('error', 'code'))
    assert_equal [{ 'jsonrpc' => '2.0', 'id' => 2, 'result' => {} }], replies[1] # a batch gets a batch back
    assert_equal(-32_600, replies[2].dig('error', 'code'))
    assert_equal 5, replies[3]['id']
    assert_equal 4, replies.size
  end

  def test_accented_paths_in_the_environment
    dir = File.join(@dir, 'Domótica')
    with_env('LEAP_BACKUP_DIR' => dir.b) do # Ruby marks it binary when no language is set
      config = Leapctl::Config.load('host' => 'fake')
      c = Leapctl::Client.new(config, transport: @bridge, settle: 0)
      lines = Leapctl::Commands.call(c, 'rename-device', 'device' => 'Lamp', 'name' => 'Desk Lamp')
      assert_match(/Domótica/, lines.join("\n"))
      assert_includes lines, Leapctl::Commands::HA_NAMES
    end
  end

  def test_backup_layout_is_the_same_on_every_ruby
    refute_match(/\[\n\s*\]/, File.read(@c.backup))
  end

  def test_a_relative_backup_folder_works_for_restore
    Dir.chdir(@dir) do
      c = Leapctl::Client.new(Leapctl::Config.new('host' => 'fake', 'backup_dir' => 'rel'), transport: @bridge, settle: 0)
      before = c.backup
      assert_empty c.restore(before, dry_run: true)
      assert_empty c.restore(File.basename(before), dry_run: true)
    end
  end

  # ---- found in the final check -------------------------------------------------------------------

  def test_clear_button_says_what_it_cleared
    result = @c.clear_button('/button/200')
    assert_match(%r{Kitchen / Bedside Button 1: cleared 1 action; template /vbutton/1: cleared 1 action; shared with Kitchen / Bedside 2 Button 1: cleared 1 action}, result)
    @bridge.template('/vbutton/3', '/area/2', 'Bedside', 'Alert', 0, 303) # a second, identical template: unclear
    %w[/preset/303 /preset/301 /preset/200].each { |p| @bridge.assignment(p, '/zone/1', 100) }
    @c.refresh
    assert_match(/WARNING: can't tell which Lutron template/, @c.clear_button('/button/200'))
  end

  def test_a_change_refused_before_any_write_leaves_no_backup
    assert_raises(Leapctl::Error) { Leapctl::Commands.call(@c, 'rename-device', 'device' => 'Nope', 'name' => 'x') }
    assert_empty @c.backups
    assert_raises(Leapctl::Error) { Leapctl::Commands.call(@c, 'clear-button', 'button' => '/button/100') } # the bridge refuses after a write
    assert_equal 1, @c.backups.size
  end

  def test_backups_of_another_bridge_are_refused_and_skipped
    mine = @c.backup
    snap = JSON.parse(File.read(mine))
    snap['project']['GUID'] = 'another-bridge'
    File.write(other = File.join(@dir, '29990101-000000.json'), JSON.generate(snap)) # sorts newest
    err = assert_raises(Leapctl::Error) { @c.restore(File.basename(other), dry_run: true) }
    assert_match(/another bridge/, err.message)
    assert_equal mine, Leapctl::Commands.latest_backup(@c)
    File.write(File.join(@dir, 'latest.json'), File.read(mine)) # e.g. a snapshot kept in the same folder
    refute_includes @c.backups, File.join(@dir, 'latest.json')
  end

  def test_setup_treats_address_files_and_ca_as_one_set
    ha = File.join(@dir, 'ha')
    FileUtils.mkdir_p(File.join(ha, '.storage'))
    cert, key = cert_pair(ha, 'lutron_caseta-192.168.1.20')
    File.write(ca = File.join(ha, 'lutron_caseta-192.168.1.20-ca.pem'), @@pair[0])
    entry = { 'domain' => 'lutron_caseta', 'data' => { 'host' => '192.168.1.20', 'certfile' => File.basename(cert), 'keyfile' => File.basename(key), 'ca_certs' => File.basename(ca) } }
    File.write(File.join(ha, '.storage', 'core.config_entries'), JSON.generate('data' => { 'entries' => [entry] }))
    File.write(File.join(ha, 'configuration.yaml'), "default_config:\n")
    picked = Leapctl::Setup.settings({ 'from_home_assistant' => File.join(ha, 'configuration.yaml'), 'cert' => cert, 'key' => key })
    assert_equal({ 'host' => '192.168.1.20', 'cert' => cert, 'key' => key, 'ca' => ca }, picked)
    other_cert, other_key = cert_pair(@dir, 'elsewhere')
    assert_raises(Leapctl::Error) { Leapctl::Setup.settings({ 'from_home_assistant' => ha, 'cert' => other_cert, 'key' => other_key }) }
    assert_nil Leapctl::Setup.settings({ 'host' => '10.0.0.2', 'cert' => other_cert, 'key' => other_key })['ca']
    with_env('LEAPCTL_CONFIG' => File.join(@dir, 'set.json')) do
      Leapctl::Config.save(picked)
      Leapctl::Config.save('host' => '10.0.0.2', 'cert' => other_cert, 'key' => other_key, 'ca' => nil)
      refute Leapctl::Config.read_file.key?('ca') # the old bridge's CA doesn't stay behind
    end
    err = assert_raises(Leapctl::Error) { Leapctl::CertFinder.home_assistant('smb://homeassistant.local/config') }
    assert_match(/network address/, err.message)
  end

  def test_settings_file_edge_cases
    real = File.join(@dir, 'dotfiles', 'leapctl.json')
    FileUtils.mkdir_p(File.dirname(real))
    File.write(real, '{"backup_dir": "/tmp/x"}')
    File.symlink(real, link = File.join(@dir, 'config.json'))
    with_env('LEAPCTL_CONFIG' => link, 'LEAP_BACKUP_DIR' => File.join(@dir, 'elsewhere')) do
      Leapctl::Config.save('host' => '10.0.0.3')
      assert File.symlink?(link) # written through the link
      assert_equal '10.0.0.3', JSON.parse(File.read(real))['host']
      assert_match(/LEAP_BACKUP_DIR is set .* backup dir/, Leapctl::Setup.overridden('backup_dir' => File.join(@dir, 'mine')).join)
      next if Process.uid.zero?
      File.chmod(0, real)
      err = assert_raises(Leapctl::Error) { Leapctl::Config.load }
      assert_match(/can't read .*Permission denied/, err.message)
      File.chmod(0o600, real)
    end
  end

  def test_programming_finds_remotes_by_room
    assert_match(%r{\ADen / Pico}, Leapctl::Commands.call(@c, 'programming', 'device' => 'Den').first)
    err = assert_raises(Leapctl::Error) { @c.find_remote('Attic') }
    assert_match(/`leapctl programming` lists them/, err.message)
  end

  def test_snapshot_copy_has_no_time_and_is_private
    snap = File.join(@dir, 'snapshot.json')
    File.write(snap, '{}')
    File.chmod(0o644, snap)
    c = Leapctl::Client.new(Leapctl::Config.new('host' => 'fake', 'backup_dir' => @dir, 'snapshot' => snap), transport: @bridge, settle: 0)
    c.backup
    refute JSON.parse(File.read(snap)).key?('taken_at')
    assert_equal 0o600, File.stat(snap).mode & 0o777
  end

  def test_mcp_survives_odd_ids_and_refuses_odd_hosts
    lines = ['{"jsonrpc":"2.0","id":1e400,"method":"ping"}', '{"jsonrpc":"2.0","id":"\udfff","method":"\udfff"}',
             '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"lutron_setup","arguments":{"host":"999.999.999.999","confirm":true}}}',
             '{"jsonrpc":"2.0","id":4,"method":"ping"}']
    output = StringIO.new
    capture_io { Leapctl::MCP.new(@config, input: StringIO.new(lines.join("\n") + "\n"), output: output, client: -> { @c }).run }
    replies = output.string.lines.map { |l| JSON.parse(l) }
    assert_equal(-32_600, replies[0].dig('error', 'code'))
    assert_equal(-32_601, replies[1].dig('error', 'code'))
    assert_match(/must be the bridge's IP address/, replies[2].dig('result', 'content', 0, 'text'))
    assert_equal 4, replies[3]['id']
  end

  def test_connections_time_out_and_point_to_setup
    cert, key = cert_pair(@dir, 'client')
    tcp = TCPServer.new('127.0.0.1', 0)
    port = tcp.addr[1]
    thread = Thread.new { s = tcp.accept; sleep 5; s.close } # accepts, never answers TLS
    started = Time.now
    err = assert_raises(Leapctl::Error) { Leapctl::TlsTransport.new('127.0.0.1', cert, key, port: port, connect_timeout: 0.5) }
    assert_match(/no answer/, err.message)
    assert_operator Time.now - started, :<, 3
    tcp.close
    err = assert_raises(Leapctl::Error) { Leapctl::TlsTransport.new('127.0.0.1', cert, key, port: port) } # nothing listens now
    assert_match(/run `leapctl setup --from-home-assistant/, err.message)
  ensure
    thread&.kill
  end

  def test_pair_listens_ten_minutes_at_most
    err = assert_raises(Leapctl::Error) { Leapctl::Commands.call(@c, 'pair', 'area' => 'Kitchen', 'auto_program' => false, 'minutes' => 30) }
    assert_match(/at most 10/, err.message)
    assert_empty @c.backups # refused before anything happened
  end
end
