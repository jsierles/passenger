#  Phusion Passenger - http://www.modrails.com/
#  Copyright (C) 2008  Phusion
#
#  Phusion Passenger is a trademark of Hongli Lai & Ninh Bui.
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; version 2 of the License.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License along
#  with this program; if not, write to the Free Software Foundation, Inc.,
#  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

require 'rubygems'
require 'thread'
if RUBY_PLATFORM != "java" && RUBY_VERSION < "1.8.7"
	require 'fastthread'
end
require 'pathname'
require 'etc'
require 'tempfile'
require 'passenger/exceptions'
if RUBY_PLATFORM != "java"
	require 'passenger/native_support'
end

module Passenger

# Utility functions.
module Utils
protected
	GENUINE_PHUSION_PASSENGER_NAMESPACE = Passenger

	# Return the absolute version of +path+. This path is guaranteed to
	# to be "normal", i.e. it doesn't contain stuff like ".." or "/",
	# and it correctly respects symbolic links.
	#
	# Raises SystemCallError if something went wrong. Raises ArgumentError
	# if +path+ is nil. Raises InvalidPath if +path+ does not appear
	# to be a valid path.
	def normalize_path(path)
		raise ArgumentError, "The 'path' argument may not be nil" if path.nil?
		return Pathname.new(path).realpath.to_s
	rescue Errno::ENOENT => e
		raise InvalidAPath, e.message
	end
	
	# Assert that +app_root+ is a valid Ruby on Rails application root.
	# Raises InvalidPath if that is not the case.
	def assert_valid_app_root(app_root)
		assert_valid_directory(app_root)
		assert_valid_file("#{app_root}/config/environment.rb")
	end
	
	# Assert that +path+ is a directory. Raises +InvalidPath+ if it isn't.
	def assert_valid_directory(path)
		if !File.directory?(path)
			raise InvalidPath, "'#{path}' is not a valid directory."
		end
	end
	
	# Assert that +path+ is a file. Raises +InvalidPath+ if it isn't.
	def assert_valid_file(path)
		if !File.file?(path)
			raise InvalidPath, "'#{path}' is not a valid file."
		end
	end
	
	# Assert that +username+ is a valid username. Raises
	# ArgumentError if that is not the case.
	def assert_valid_username(username)
		# If username does not exist then getpwnam() will raise an ArgumentError.
		username && Etc.getpwnam(username)
	end
	
	# Assert that +groupname+ is a valid group name. Raises
	# ArgumentError if that is not the case.
	def assert_valid_groupname(groupname)
		# If groupname does not exist then getgrnam() will raise an ArgumentError.
		groupname && Etc.getgrnam(groupname)
	end
	
	def close_all_io_objects_for_fds(file_descriptors_to_close)
		ObjectSpace.each_object do |o|
			if o.is_a?(IO)
				begin
					if o.closed? && file_descriptors_to_close.include?(o.fileno)
						o.close
					end
				rescue
				end
			end
		end
	end
	
	def marshal_exception(exception)
		temporarily_restore_phusion_passenger_namespace do
			data = {
				:message => exception.message,
				:class => exception.class.to_s,
				:backtrace => exception.backtrace
			}
			if exception.is_a?(InitializationError)
				data[:is_initialization_error] = true
				if exception.child_exception
					data[:child_exception] = marshal_exception(exception.child_exception)
				end
			else
				begin
					data[:exception] = Marshal.dump(exception)
				rescue ArgumentError, TypeError
					e = UnknownError.new(exception.message, exception.class.to_s,
								exception.backtrace)
					data[:exception] = Marshal.dump(e)
				end
			end
			return Marshal.dump(data)
		end
	end
	
	def unmarshal_exception(data)
		hash = Marshal.load(data)
		if hash[:is_initialization_error]
			if hash[:child_exception]
				child_exception = unmarshal_exception(hash[:child_exception])
			else
				child_exception = nil
			end
			
			case hash[:class]
			when AppInitError.to_s
				exception_class = AppInitError
			when FrameworkInitError.to_s
				exception_class = FrameworkInitError
			else
				exception_class = InitializationError
			end
			return exception_class.new(hash[:message], child_exception)
		else
			begin
				return Marshal.load(hash[:exception])
			rescue ArgumentError, TypeError
				return UnknownError.new(hash[:message], hash[:class], hash[:backtrace])
			end
		end
	end
	
	# Print the given exception, including the stack trace, to STDERR.
	#
	# +current_location+ is a string which describes where the code is
	# currently at. Usually the current class name will be enough.
	def print_exception(current_location, exception)
		if !exception.is_a?(SystemExit)
			STDERR.puts(exception.backtrace_string(current_location))
			STDERR.flush
		end
	end
	
	# Fork a new process and run the given block inside the child process, just like
	# fork(). Unlike fork(), this method is safe, i.e. there's no way for the child
	# process to escape the block. Any uncaught exceptions in the child process will
	# be printed to standard output, citing +current_location+ as the source.
	# Futhermore, the child process will exit by calling Kernel#exit!, thereby
	# bypassing any at_exit or ensure blocks.
	#
	# If +double_fork+ is true, then the child process will fork and immediately exit.
	# This technique can be used to avoid zombie processes, at the expense of not
	# being able to waitpid() the second child.
	def safe_fork(current_location = self.class, double_fork = false)
		pid = fork
		if pid.nil?
			begin
				if double_fork
					pid2 = fork
					if pid2.nil?
						yield
					end
				else
					yield
				end
			rescue Exception => e
				print_exception(current_location.to_s, e)
			ensure
				exit!
			end
		else
			if double_fork
				Process.waitpid(pid)
				return pid
			else
				return pid
			end
		end
	end
	
	# Run the given block. A message will be sent through +channel+ (a
	# MessageChannel object), telling the remote side whether the block
	# raised an exception, called exit(), or succeeded.
	# Returns whether the block succeeded.
	# Exceptions are not propagated, except for SystemExit.
	def report_app_init_status(channel)
		begin
			old_global_stderr = $stderr
			old_stderr = STDERR
			stderr_output = ""
			tempfile = Tempfile.new('passenger-stderr')
			tempfile.unlink
			Object.send(:remove_const, 'STDERR') rescue nil
			Object.const_set('STDERR', tempfile)
			begin
				yield
			ensure
				Object.send(:remove_const, 'STDERR') rescue nil
				Object.const_set('STDERR', old_stderr)
				$stderr = old_global_stderr
				if tempfile
					tempfile.rewind
					stderr_output = tempfile.read
					tempfile.close rescue nil
				end
			end
			channel.write('success')
			return true
		rescue StandardError, ScriptError, NoMemoryError => e
			if ENV['TESTING_PASSENGER'] == '1'
				print_exception(self.class.to_s, e)
			end
			channel.write('exception')
			channel.write_scalar(marshal_exception(e))
			channel.write_scalar(stderr_output)
			return false
		rescue SystemExit => e
			channel.write('exit')
			channel.write_scalar(marshal_exception(e))
			channel.write_scalar(stderr_output)
			raise
		end
	end
	
	# Receive status information that was sent to +channel+ by
	# report_app_init_status. If an error occured according to the
	# received information, then an appropriate exception will be
	# raised.
	#
	# Raises:
	# - AppInitError
	# - IOError, SystemCallError, SocketError
	def unmarshal_and_raise_errors(channel, app_type = "rails")
		args = channel.read
		if args.nil?
			raise EOFError, "Unexpected end-of-file detected."
		end
		status = args[0]
		if status == 'exception'
			child_exception = unmarshal_exception(channel.read_scalar)
			stderr = channel.read_scalar
			#print_exception(self.class.to_s, child_exception)
			raise AppInitError.new(
				"Application '#{@app_root}' raised an exception: " <<
				"#{child_exception.class} (#{child_exception.message})",
				child_exception,
				app_type,
				stderr.empty? ? nil : stderr)
		elsif status == 'exit'
			child_exception = unmarshal_exception(channel.read_scalar)
			stderr = channel.read_scalar
			raise AppInitError.new("Application '#{@app_root}' exited during startup",
				child_exception, app_type, stderr.empty? ? nil : stderr)
		end
	end
	
	# Lower the current process's privilege to the owner of the given file.
	# No exceptions will be raised in the event that privilege lowering fails.
	def lower_privilege(filename, lowest_user = "nobody")
		stat = File.lstat(filename)
		begin
			if !switch_to_user(stat.uid)
				switch_to_user(lowest_user)
			end
		rescue Errno::EPERM
			# No problem if we were unable to switch user.
		end
	end

	def switch_to_user(user)
		begin
			if user.is_a?(String)
				pw = Etc.getpwnam(user)
				username = user
				uid = pw.uid
				gid = pw.gid
			else
				pw = Etc.getpwuid(user)
				username = pw.name
				uid = user
				gid = pw.gid
			end
		rescue
			return false
		end
		if uid == 0
			return false
		else
			# Some systems are broken. initgroups can fail because of
			# all kinds of stupid reasons. So we ignore any errors
			# raised by initgroups.
			begin
				Process.groups = Process.initgroups(username, gid)
			rescue
			end
			Process::Sys.setgid(gid)
			Process::Sys.setuid(uid)
			ENV['HOME'] = pw.dir
			return true
		end
	end
	
	# Some applications have a model named 'Passenger'.
	# This method removes the Passenger module from the
	# global namespace.
	def remove_phusion_passenger_namespace
		if defined?(::Passenger) && ::Passenger == GENUINE_PHUSION_PASSENGER_NAMESPACE
			Object.send(:remove_const, :Passenger)
		end
	end
	
	# The current 'Passenger' namespace might be reserved by an application.
	# This method temporarily restores the 'Passenger' namespace to that of
	# Phusion Passenger's, runs the block, then restores the 'Passenger'
	# namespace back to what it was before.
	def temporarily_restore_phusion_passenger_namespace
		if defined?(::Passenger)
			old_passenger_namespace = ::Passenger
			Object.send(:remove_const, :Passenger)
		end
		Object.const_set(:Passenger, GENUINE_PHUSION_PASSENGER_NAMESPACE)
		begin
			yield
		ensure
			Object.send(:remove_const, :Passenger)
			if old_passenger_namespace
				Object.const_set(:Passenger, old_passenger_namespace)
			end
		end
	end
	
	# Sigh... there's no portable way to query the current process's memory usage. :-(
	# So we'll use an army of platform-specific functions to query/estimate the
	# memory usage.
	
	# Get the current process's memory usage by querying /proc/self/smaps.
	# The private dirty RSS of the current process will be queried. This is
	# by far the most accurate way of measuring memory usage.
	#
	# As far as I know, Linux is the only operating system that supports this.
	#
	# Returns the memory usage in MB, or nil if the information could not be
	# queried.
	#
	# The first time this method is called (and successfully returns), it will set
	# @@memory_usage_throttling_interval, which is a Float which indicates how much
	# time a program should wait between two get_vm_size calls in order to get good
	# performance. get_vm_size might be an expensive operation.
	def get_memory_usage_by_using_smaps
		total = 0
		File.read("/proc/self/smaps").split("\n").each do |line|
			line =~ /^(Private)_Dirty: +(\d+)/
			if $2
				total += $2.to_i
			end
		end
		if total == 0
			return nil
		else
			# 'total' is in KB.
			@@memory_usage_throttling_interval ||= 0.25
			return total / 1024.0
		end
	rescue SystemCallError, IOError
		return nil
	end
	
	# Get the current process's VM size by querying /proc/self/status.
	#
	# Some Linux systems don't have /proc/self/smaps or don't have a usable
	# /proc/self/smaps, for whatever reason. In that case, this method may be
	# used instead to estimate the memory usage.
	#
	# FreeBSD with /proc mounted with linprocfs also supports /proc/self/status.
	# It's recommended that the system administrator mounts /proc with linprocfs
	# instead of procfs, because FreeBSD provides no other lightweight way to
	# query memory usage. Using 'ps' (like get_memory_usage_by_using_ps) is much,
	# MUCH slower and should generally be avoided.
	#
	# Returns the VM size in MB, or nil if the information could not be
	# queried.
	def get_vm_size_by_using_status
		File.read("/proc/self/status") =~ /^VmSize: *(.*) kB$/
		if $1
			# $1 is in KB.
			return $1.to_i / 1024.0
		else
			return nil
		end
	rescue SystemCallError, IOError
		return nil
	end
	
	# Get the current process's VM size by querying the 'ps' command.
	# This is the most portable way to obtain the VM size, but is also the slowest,
	# than thus should be avoided whenever possible.
	#
	# Returns the VM size in MB, or nil if the information could not be
	# queried.
	def get_vm_size_by_using_ps
		output = `ps -p#{$$} -o vsz`
		if output.nil?
			return nil
		else
			output.strip!
			vm_size = output.split(/\n/)[1]
			vm_size.strip!
			return vm_size.to_i / 1024.0   # vm_size is in KB.
		end
	end
	
	# Get the current process's VM size by using whatever method is the best for the
	# current platform.
	#
	# Returns the VM size in MB, or nil if the information could not be
	# queried.
	#
	# The first time this method is called (and successfully returns), it will set
	# @@memory_usage_throttling_interval, which is a Float which indicates how much
	# time a program should wait between two get_vm_size calls in order to get good
	# performance. get_vm_size might be an expensive operation.
	def get_vm_size
		vm_size = get_vm_size_by_using_status
		if vm_size
			alias get_vm_size get_vm_size_by_using_status
			@@memory_usage_throttling_interval = 0.1
			return vm_size
		end
		
		vm_size = get_vm_size_by_using_ps
		if vm_size
			alias get_vm_size get_vm_size_by_using_ps
			@@memory_usage_throttling_interval = 1.0
			return vm_size
		end
		
		def get_vm_size
			return nil
		end
		return nil
	end
	
	# Estimate the current process's memory usage, by querying its VM size.
	# This is less accurrate than get_memory_usage_by_using_smaps.
	#
	# Returns the estimated memory usage in MB, or nil if the information
	# cannot be queried.
	#
	# The first time this method is called (and successfully returns), it will set
	# @@memory_usage_throttling_interval, which is a Float which indicates how much
	# time a program should wait between two get_vm_size calls in order to get good
	# performance. get_vm_size might be an expensive operation.
	def get_memory_usage_estimation
		# The VM size is almost definitely higher than the actual memory
		# usage because it also counts unused memory pages and shared
		# memory. Oh the other hand, the Resident Set Size (RSS) can be
		# either too high (because it counts shared memory) or too low
		# (because swapped out memory is not counted).
		#
		# Let's just hope that an estimation based on the VM size is
		# correct. We estimate differently depending on whether the
		# Ruby garbage collector is copy-on-write friendly. The following
		# multipliers are based on memory usage data from memory
		# benchmarks with several Rails apps.
		vm_size = get_vm_size
		if vm_size
			@@mem_estimation_multiplier ||= begin
				if GC.copy_on_write_friendly?
					0.58 * 0.7
				else
					0.58
				end
			end
			return vm_size * @@mem_estimation_multiplier
		else
			return nil
		end
	end
	
	# Get the memory usage for the current process. This may not be the
	# exact memory usage, and may be just an estimation.
	#
	# Internally, this method will use whatever is the best way to obtain
	# the memory usage for the current platform. Because obtaining the
	# memory usage might be an expensive operation, this method also does
	# caching.
	#
	# Returns the estimated memory usage in MB, or nil if the information
	# cannot be queried.
	def get_memory_usage
		@@last_memory_usage_query_time = nil
		if get_memory_usage_by_using_smaps
			method = "get_memory_usage_by_using_smaps"
		elsif get_vm_size
			method = "get_memory_usage_estimation"
		else
			source = %q{
				def get_memory_usage
					return nil
				end
			}
		end
		source ||= %Q{
			def get_memory_usage
				current_time = Time.now
				if @@last_memory_usage_query_time
					if current_time - @@last_memory_usage_query_time >
					   #{@@memory_usage_throttling_interval}
						@@last_memory_usage_query_time = current_time
						@@last_memory_usage = #{method}
					end
				else
					@@last_memory_usage_query_time = current_time
					@@last_memory_usage = #{method}
				end
				return @@last_memory_usage
			end
		}
		eval source
		return get_memory_usage
	end
end

end # module Passenger

class Exception
	def backtrace_string(current_location = nil)
		if current_location.nil?
			location = nil
		else
			location = "in #{current_location} "
		end
		return "*** Exception #{self.class} #{location}" <<
			"(#{self}) (process #{$$}):\n" <<
			"\tfrom " << backtrace.join("\n\tfrom ")
	end
end

class ConditionVariable
	# This is like ConditionVariable.wait(), but allows one to wait a maximum
	# amount of time. Returns true if this condition was signaled, false if a
	# timeout occurred.
	def timed_wait(mutex, secs)
		require 'timeout' unless defined?(Timeout)
		if secs > 0
			if secs > 100000000
				# NOTE: If one calls timeout() on FreeBSD 5 with an
				# argument of more than 100000000, then Ruby will become
				# stuck in an infite loop, blocking all threads. It seems
				# that Ruby uses select() to implement sleeping.
				# I think that a value of more than 100000000 overflows
				# select()'s data structures, causing it to behave incorrectly.
				# So we just make sure we can't sleep more than 100000000
				# seconds.
				secs = 100000000
			end
			Timeout.timeout(secs) do
				wait(mutex)
			end
		else
			wait(mutex)
		end
		return true
	rescue Timeout::Error
		return false
	end
	
	# This is like ConditionVariable.wait(), but allows one to wait a maximum
	# amount of time. Raises Timeout::Error if the timeout has elapsed.
	def timed_wait!(mutex, secs)
		require 'timeout' unless defined?(Timeout)
		if secs > 0
			if secs > 100000000
				# See the note for timed_wait().
				secs = 100000000
			end
			Timeout.timeout(secs) do
				wait(mutex)
			end
		else
			wait(mutex)
		end
	end
end

class IO
	# ApplicationSpawner/FrameworkSpawner might temporarily undefine
	# the 'Passenger' module in order to avoid namespace collissions
	# with the spawned application. So we save the NativeSupport
	# module in a constant so that we can access it whether
	# our 'Passenger' module is defined or not.
	NATIVE_SUPPORT = Passenger::NativeSupport

	# Send an IO object (i.e. a file descriptor) over this IO channel.
	# This only works if this IO channel is a Unix socket.
	#
	# Raises SystemCallError if something went wrong.
	def send_io(io)
		NATIVE_SUPPORT.send_fd(self.fileno, io.fileno)
	end
	
	# Receive an IO object (i.e. a file descriptor) from this IO channel.
	# This only works if this IO channel is a Unix socket.
	#
	# Raises SystemCallError if something went wrong.
	def recv_io
		return IO.new(NATIVE_SUPPORT.recv_fd(self.fileno))
	end
end

# Ruby's implementation of UNIXSocket#recv_io and UNIXSocket#send_io
# are broken on 64-bit FreeBSD 7. So we override them with our own
# implementation.
if RUBY_PLATFORM =~ /freebsd/
	require 'socket'
	UNIXSocket.class_eval do
		def recv_io
			super
		end

		def send_io(io)
			super
		end
	end
end

module GC
	if !respond_to?(:copy_on_write_friendly?)
		# Checks whether the current Ruby interpreter's garbage
		# collector is copy-on-write friendly.
		def self.copy_on_write_friendly?
			return false
		end
	end
end
