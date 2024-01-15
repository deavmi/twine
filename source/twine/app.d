module twine.app;

import std.stdio;

import twine.logging;

void main(string[] args)
{
	import twine.netd;
	import twine.six.ll;

	import twine.core.router;

	if(args.length <= 2)
	{
		logger.error("Need identity and at least one interface to run on");
		return;
	}
	
	string identity = args[1];
	string[] interfaces = args[2..$];

	Router r = new Router([identity, "privKey1"]);


	import niknaks.debugging;
    writeln("Will run on link-local interfaces:\n\n"~dumpArray!(interfaces));

	// add all link-local interfaces
	foreach(string if_name; interfaces)
	{
		logger.info("Adding interface '"~if_name~"'...");
		LLInterface lli = new LLInterface(if_name);
		r.getLinkMan().addLink(lli);
		logger.info("Adding interface '"~if_name~"'... [done]");
	}
	

	// start the router
	r.start();

	import core.thread;
	while(true)
	{
		r.dumpRoutes();
		Thread.sleep(dur!("seconds")(5));
	}
}
