module twine.app;

import std.stdio;

void main()
{
	writeln("Edit source/app.d to start your project.");

	import twine.six.ll : LLInterface, determineInterfaceAddresses, InterfaceInfo;
	import twine.core.router;

	Router r = new Router(["pubKey1", "privKey1"]);

	// todo, for now i detect all interfaces which have link-local
	InterfaceInfo[] allLinkLocalInterfaces;
	determineInterfaceAddresses(allLinkLocalInterfaces);
	import niknaks.debugging;
    writeln("Will run on link-local interfaces:\n\n"~dumpArray!(allLinkLocalInterfaces));


	// add all link-local interfaces
	foreach(InterfaceInfo if_; allLinkLocalInterfaces)
	{
		LLInterface lli = new LLInterface(if_);
		r.getLinkMan().addLink(lli);
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
