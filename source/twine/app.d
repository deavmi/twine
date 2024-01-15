module twine.app;

import std.stdio;

import twine.logging;

void main(string[] args)
{
	import twine.six.ll : LLInterface, InterfaceInfo, getIfAddrs, getLinkLocal;

	import twine.core.router;

	Router r = new Router(["pubKey1", "privKey1"]);


	import niknaks.debugging;
    writeln("Will run on link-local interfaces:\n\n"~dumpArray!(args));

	// add all link-local interfaces
	foreach(string if_name; args[1..$])
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
