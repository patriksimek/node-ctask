cluster = require 'cluster'
EventEmitter = require('events').EventEmitter

class Scheduler extends EventEmitter
	jobs: {}
	workers: []
	employed: {}
	timers: {}
	locked: false
	
	constructor: () ->
		handler = (msg, worker) =>
			if msg?._node_scheduler
				job = @jobs[msg._node_scheduler.job]
				
				switch msg._node_scheduler.action
					when 'complete'
						@_status "Job \"#{job.name}\" completed by worker #{worker.id} in #{new Date().getTime() - @timers[worker.id]}ms"

						delete @timers[worker.id]
						delete @employed[worker.id]
						@workers.push worker
						
						@_complete msg._node_scheduler.error, job
						
					when 'unlock'
						@_status "Job \"#{job.name}\" unlocked by worker #{worker.id}"
							
						job.locked = false
			
		if cluster.isMaster
			for id, worker of cluster.workers
				do (worker) =>
					@workers.push worker
					worker.on 'message', (msg) =>
						handler.call @, msg, worker

			cluster.on 'fork', (worker) =>
				@workers.push worker

				worker.on 'message', (msg) =>
					handler.call @, msg, worker
					
			cluster.on 'exit', (worker) =>
				@workers.splice @workers.indexOf(worker), 1
				
				## TODO: Logic about disconnecting a worker that has running task

		if cluster.isWorker
			process.on 'message', (msg) =>
				if msg?._node_scheduler
					switch msg._node_scheduler.action
						when 'trigger'
							@_trigger msg._node_scheduler.job
	
	attach: (job) ->
		if @jobs[job.name]
			@_error "Job \"#{job.name}\" already exist!"
			return job

		@jobs[job.name] = job

		if job.shared
			if cluster.isMaster
				unless @workers.length
					@_status "No workers for shared jobs"
					
				job._interval = setInterval () =>
					if job.running and not job.multi then return
					if @locked or job.locked or not job.enabled then return
					
					if @workers.length
						worker = @workers.shift()
						@employed[worker.id] = worker
						@timers[worker.id] = new Date().getTime()
						
						@_status "Job starting \"#{job.name}\" by worker #{worker.id}"

						job.running = true
						if job.locking then job.locked = true

						worker.send
							_node_scheduler:
								action: 'trigger'
								job: job.name
					
				, job.interval
			
		else
			if not cluster.isWorker
				job._interval = setInterval () =>
					if job.running and not job.multi then return
					if @locked or job.locked or not job.enabled then return
					
					@_status "Starting job \"#{job.name}\""
						
					job.running = true
					if job.locking then job.locked = true
					
					start = new Date().getTime()
					job.action?.call job.context ? @, job, (err) =>
						@_status "Job \"#{job.name}\" completed in #{new Date().getTime() - start}ms"
						@_complete err, job
					
				, job.interval
		
		@_status "Job \"#{job.name}\" attached"
		
		job
	
	detach: (job) ->
		unless @jobs[job.name]
			return false
	
		if job.running
			job.detachWhenPossible = true
			return true
	
		delete @jobs[job.name]
			
		clearInterval job._interval
		job._interval = null

		@_status "Job \"#{job.name}\" detached"

		job
		
	_complete: (err, job) ->
		job.running = false
		job.locked = false
		
		if err
			@_error "Job \"#{job.name}\" finshed with error: #{err}"
		
		if job.detachWhenPossible
			delete job.detachWhenPossible
			@detach job

	_trigger: (jobname) ->
		job = @jobs[jobname]
		
		unless job
			process.send
				_node_scheduler:
					action: 'complete'
					job: jobname
					error: "Job not found on worker #{cluster.worker.id}"
		
		else
			job.action?.call job.context ? @, job, (err) =>
				process.send
					_node_scheduler:
						action: 'complete'
						job: job.name
						error: err
						
	_status: (msg) ->
		@emit 'status', msg
		
	_error: (msg) ->
		@emit 'error', msg
		
class Job
	shared: false
	multi: false
	action: null
	locking: false
	enabled: true
	
	constructor: (cfg) ->
		for i of cfg
			@[i] = cfg[i]
		
	start: () ->
		module.exports.Scheduler.attach @
	
	stop: () ->
		module.exports.Scheduler.detach @

	lock: () ->
		if @shared and cluster.isWorker
			process.send
				_node_scheduler:
					action: 'lock'
					job: @name
					
		else
			@locked = true
		
	unlock: () ->
		if @shared and cluster.isWorker
			process.send
				_node_scheduler:
					action: 'unlock'
					job: @name
					
		else
			@locked = false
			
module.exports.Scheduler = new Scheduler
module.exports.Job = Job