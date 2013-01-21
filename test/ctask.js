var cluster = require('cluster');

Scheduler = require('../lib/ctask').Scheduler;
Job = require('../lib/ctask').Job;

Scheduler.on('status', function (msg) {
	console.log(msg);
});

Scheduler.on('error', function (msg) {
	console.log(msg);
});

if (cluster.isMaster) {
    cluster.fork();
    cluster.fork();
    cluster.fork();
    cluster.fork();
}

new Job({
	name: 'my-first-task',
	interval: 100,
	shared: true,
	multi: true,
	context: this,
	locking: true,
	action: function (job, callback) {
		setTimeout(function() {
			// do something
			job.unlock();
			setTimeout(function() {
				callback()
			}, 5000);
		}, 1000);
	}
}).start();