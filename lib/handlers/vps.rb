require 'lib/executor'
require 'lib/handlers/backuper'

require 'erb'
require 'tempfile'
require 'fileutils'

class VPS < Executor
  class << self
    alias_method :new_orig, :new

    def new(*args)
      Kernel.const_get([:zfs, :zfs_compat].include?($CFG.get(:vpsadmin, :fstype)) ? :ZfsVPS : :VPS).new_orig(*args)
    end
  end

  def start
    @update = true

    acquire_lock_unless(zfs?) do
      try_harder do
        vzctl(:start, @veid, {}, false, [32,])
        vzctl(:set, @veid, {:onboot => "yes"}, true)
      end
    end
  end

  def stop(params = {})
    @update = true

    acquire_lock_unless(zfs?) do
      try_harder do
        vzctl(:stop, @veid, {}, false, params[:force] ? [5, 66] : [])
        vzctl(:set, @veid, {:onboot => "no"}, true)
      end
    end
  end

  def restart
    @update = true

    acquire_lock_unless(zfs?) do
      vzctl(:restart, @veid)
      vzctl(:set, @veid, {:onboot => "yes"}, true)
    end
  end

  def create
    vzctl(:create, @veid, {
        :ostemplate => @params["template"],
        :hostname => @params["hostname"],
        :private => ve_private,
    })
    vzctl(:set, @veid, {
        :applyconfig => "basic",
        :nameserver => @params["nameserver"],
    }, true)
  end

  def destroy
    assume_lock do # cannot wait for lock as the VPS is already deleted from database
      stop
      vzctl(:destroy, @veid)
    end
  end

  def suspend
    acquire_lock do
      unless File.exists?("#{ve_private}/sbin/iptables-save")
        File.symlink("/bin/true", "#{ve_private}/sbin/iptables-save")
        del = true
      end

      vzctl(:suspend, @veid, {:dumpfile => dumpfile})

      File.delete("#{ve_private}/sbin/iptables-save") if del
    end
  end

  def resume
    acquire_lock do
      unless File.exists?("#{ve_private}/sbin/iptables-restore")
        File.symlink("/bin/true", "#{ve_private}/sbin/iptables-restore")
        del = true
      end

      vzctl(:resume, @veid, {:dumpfile => dumpfile})

      File.delete("#{ve_private}/sbin/iptables-restore") if del
    end
  end

  def reinstall
    acquire_lock do
      honor_state do
        stop
        destroy
        create
        vzctl(:set, @veid, {:ipadd => @params["ip_addrs"]}, true) if @params["ip_addrs"].count > 0
      end
    end
  end

  def set_params
    vzctl(:set, @veid, @params, true)
  end

  def passwd
    vzctl(:set, @veid, {:userpasswd => "#{@params["user"]}:#{@params["password"]}"})
    @passwd = true
    ok
  end

  def applyconfig
    acquire_lock do
      @params["configs"].each do |cfg|
        vzctl(:set, @veid, {:applyconfig => cfg, :setmode => "restart"}, true)
      end
    end
  end

  def features
    acquire_lock do
      honor_state do
        stop
        vzctl(:set, @veid, {
            :feature => ["nfsd:on", "nfs:on", "ppp:on"],
            :capability => "net_admin:on",
            :iptables => ['ip_conntrack', 'ip_conntrack_ftp', 'ip_conntrack_irc', 'ip_nat_ftp',
                          'ip_nat_irc', 'ip_tables', 'ipt_LOG', 'ipt_REDIRECT', 'ipt_REJECT',
                          'ipt_TCPMSS', 'ipt_TOS', 'ipt_conntrack', 'ipt_helper', 'ipt_length',
                          'ipt_limit', 'ipt_multiport', 'ipt_state', 'ipt_tcpmss', 'ipt_tos',
                          'ipt_ttl', 'iptable_filter', 'iptable_mangle', 'iptable_nat'],
            :numiptent => "1000",
            :devices => ["c:10:200:rw", "c:10:229:rw", "c:108:0:rw"],
        }, true)
        start
        sleep(3)
        vzctl(:exec, @veid, "mkdir -p /dev/net")
        vzctl(:exec, @veid, "mknod /dev/net/tun c 10 200", false, [8,])
        vzctl(:exec, @veid, "chmod 600 /dev/net/tun")
        vzctl(:exec, @veid, "mknod /dev/fuse c 10 229", false, [8,])
        vzctl(:exec, @veid, "mknod /dev/ppp c 108 0", false, [8,])
        vzctl(:exec, @veid, "chmod 600 /dev/ppp")
      end
    end
  end

  def migrate_offline
    stop if @params["stop"]
    syscmd("#{$CFG.get(:vz, :vzmigrate)} #{@params["target"]} #{@veid}")
  end

  def migrate_online
    begin
      syscmd("#{$CFG.get(:vz, :vzmigrate)} --online #{@params["target"]} #{@veid}")
    rescue CommandFailed => err
      @output[:migration_cmd] = err.cmd
      @output[:migration_exitstatus] = err.rc
      @output[:migration_error] = err.output
      {:ret => :warning, :output => migrate_offline[:output]}
    end
  end

  def clone
    create
    syscmd("#{$CFG.get(:bin, :rm)} -rf #{$CFG.get(:vz, :vz_root)}/private/#{@veid}")

    if @params["is_local"]
      syscmd("#{$CFG.get(:bin, :cp)} -a #{$CFG.get(:vz, :vz_root)}/private/#{@params["src_veid"]}/ #{$CFG.get(:vz, :vz_root)}/private/#{@veid}")
    else
      rsync = $CFG.get(:vps, :clone, :rsync) \
        .gsub(/%\{rsync\}/, $CFG.get(:bin, :rsync)) \
        .gsub(/%\{src\}/, "#{@params["src_server_ip"]}:#{$CFG.get(:vz, :vz_root)}/private/#{@params["src_veid"]}/") \
        .gsub(/%\{dst\}/, "#{$CFG.get(:vz, :vz_root)}/private/#{@veid}")

      syscmd(rsync, [23, 24])
    end
  end

  def nas_mounts
    action_script("mount")
    action_script("umount")
  end

  def nas_mount
    dst = "#{ve_root}/#{@params["dst"]}"

    unless File.exists?(dst)
      begin
        FileUtils.mkpath(dst)

          # it means, that the folder is mounted but was removed on the other end
      rescue Errno::EEXIST => e
        syscmd("#{$CFG.get(:bin, :umount)} -f #{dst}")
      end
    end

    runscript("premount")
    syscmd("#{$CFG.get(:bin, :mount)} #{@params["mount_opts"]} -o #{@params["mode"]} #{@params["src"]} #{dst}")
    runscript("postmount")
  end

  def nas_umount(valid_rcs = [])
    runscript("preumount")
    syscmd("#{$CFG.get(:bin, :umount)} #{@params["umount_opts"]} #{ve_root}/#{@params["dst"]}", valid_rcs)
    runscript("postumount")
  end

  def nas_remount
    nas_umount([1])
    nas_mount
  end

  def action_script(action)
    path = "#{$CFG.get(:vz, :vz_conf)}/conf/#{@veid}.#{action}"
    existed = File.exists?(path)

    File.open(path, "w") do |f|
      f.write(ERB.new(File.new("templates/ve_#{action}.erb").read, 0).result(binding))
    end

    syscmd("#{$CFG.get(:bin, :chmod)} +x #{path}") unless existed

    ok
  end

  def load_file(file)
    vzctl(:exec, @veid, "cat #{file}")
  end

  def update_status(db)
    up = 0
    nproc = 0
    mem = 0
    disk = 0

    begin
      IO.popen("#{$CFG.get(:vz, :vzlist)} --no-header #{@veid}") do |io|
        status = io.read.split(" ")
        up = status[2] == "running" ? 1 : 0
        nproc = status[1].to_i

        mem_str = load_file("/proc/meminfo")[:output]
        mem = (mem_str.match(/^MemTotal\:\s+(\d+) kB$/)[1].to_i - mem_str.match(/^MemFree\:\s+(\d+) kB$/)[1].to_i) / 1024

        disk_str = vzctl(:exec, @veid, "#{$CFG.get(:bin, :df)} -k /")[:output]
        disk = disk_str.split("\n")[1].split(" ")[2].to_i / 1024
      end
    rescue

    end

    db.prepared(
        "INSERT INTO vps_status (vps_id, timestamp, vps_up, vps_nproc,
      vps_vm_used_mb, vps_disk_used_mb, vps_admin_ver) VALUES
      (?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE
      timestamp = ?, vps_up = ?, vps_nproc = ?, vps_vm_used_mb = ?,
      vps_disk_used_mb = ?, vps_admin_ver = ?",
        @veid.to_i, Time.now.to_i, up, nproc, mem, disk, VpsAdmind::VERSION,
        Time.now.to_i, up, nproc, mem, disk, VpsAdmind::VERSION
    )
  end

  def script_mount
    "#{$CFG.get(:vz, :vz_conf)}/conf/#{@veid}.mount"
  end

  def script_umount
    "#{$CFG.get(:vz, :vz_conf)}/conf/#{@veid}.umount"
  end

  def ve_conf
    "#{$CFG.get(:vz, :vz_conf)}/conf/#{@veid}.conf"
  end

  def ve_private
    $CFG.get(:vz, :ve_private).gsub(/%\{veid\}/, @veid)
  end

  def ve_root
    "#{$CFG.get(:vz, :vz_root)}/root/#{@veid}"
  end

  def dumpfile
    $CFG.get(:vps, :migration, :dumpfile).gsub(/%\{veid\}/, @veid)
  end

  def runscript(script)
    return ok unless @params[script].length > 0

    f = Tempfile.new("vpsadmind_#{script}")
    f.write("#!/bin/sh\n#{@params[script]}")
    f.close

    vzctl(:runscript, @veid, f.path)
  end

  def status
    stat = vzctl(:status, @veid)[:output].split(" ")[2..-1]
    {:exists => stat[0] == "exist", :mounted => stat[1] == "mounted", :running => stat[2] == "running"}
  end

  def honor_state
    before = status
    yield
    after = status

    if before[:running] && !after[:running]
      start
    elsif !before[:running] && after[:running]
      stop
    end

    ok
  end

  def post_save(con)
    update_status(con) if @update

    if @passwd
      con.prepared("UPDATE transactions SET t_param = '{}' WHERE t_id = ?", @command.id)
    end
  end
end
