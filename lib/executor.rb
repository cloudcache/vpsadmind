class CommandFailed < StandardError
	attr_reader :cmd, :rc, :output
	
	def initialize(cmd, rc, out)
		@cmd = cmd
		@rc = rc
		@output = out
	end
end

class CommandNotImplemented < StandardError
	
end

class Executor
	attr_accessor :output
	
	def initialize(veid, params = {}, daemon = nil)
		@veid = veid
		@params = params
		@output = {}
		@daemon = daemon
		@m_attr = Mutex.new
	end
	
	def attrs
		@m_attr.synchronize do
			yield
		end
	end
	
	def step
		attrs do
			@step
		end
	end
	
	def vzctl(cmd, veid, opts = {}, save = false, valid_rcs = [])
		options = []
		
		if opts.instance_of?(Hash)
			opts.each do |k, v|
				k = k.to_s
				v.each do |s|
					options << "#{k.start_with?("-") ? "" : "--"}#{k} #{s}"
				end
			end
		else
			options << opts
		end
		
		syscmd("#{$CFG.get(:vz, :vzctl)} #{cmd} #{veid} #{options.join(" ")} #{"--save" if save}", valid_rcs)
	end
	
	def syscmd(cmd, valid_rcs = [])
		set_step(cmd)
		
		out = ""
		puts "Executing: #{cmd}"
		IO.popen("#{cmd} 2>&1") do |io|
			out = io.read
		end
		
		if $?.exitstatus != 0 and not valid_rcs.include?($?.exitstatus)
			raise CommandFailed.new(cmd, $?.exitstatus, out)
		end
		
		{:ret => :ok, :output => out}
	end
	
	def post_save(con)
		
	end
	
	def ok
		{:ret => :ok}
	end
	
	private
	
	def set_step(str)
		attrs do
			@step = str
		end
	end
end
