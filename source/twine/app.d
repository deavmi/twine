module twine.app;

import std.stdio;

void main()
{
	writeln("Edit source/app.d to start your project.");

	import twine.six.ll : LLInterface;
	import twine.core.router;

	Router r = new Router(["pubKey1", "privKey1"]);
	LLInterface lli = new LLInterface("wlp2s0");
	r.getLinkMan().addLink(lli);
	r.start();

	import core.thread;
	while(true)
	{
		r.dumpRoutes();
		Thread.sleep(dur!("seconds")(5));
	}
}
