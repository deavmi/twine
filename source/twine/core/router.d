module twine.core.router;

import twine.logging;
import twine.links.link : Link, Receiver;
import twine.core.linkman;
import core.thread : Thread, Duration, dur;
import twine.core.wire;
import std.conv : to;
import std.datetime.systime : Clock;
import twine.core.route : Route;
import core.sync.mutex : Mutex;

public class Router : Receiver
{
    private const LinkManager linkMan; // const, never should be changed besides during construction
    private Thread advThread;
    private Duration advFreq;
    private string[] keyPairs;

    // routing tables
    private Route[string] routes;
    private Mutex routesLock;

    this()
    {
        this.linkMan = new LinkManager(this);
        
        this.advThread = new Thread(&advertiseLoop);
        this.advFreq = dur!("seconds")(5);

        this.keyPairs ~= ["pubkeyMainHost", "privKeyMainHost"]; // todo, accepts as arguments

        this.routesLock = new Mutex();

        // add self route
        installSelfRoute();
    }

    public void start()
    {
        this.advThread.start();
    }

    public final LinkManager getLinkMan()
    {
        return cast(LinkManager)this.linkMan;
    }

    private string getPublicKey()
    {
        return this.keyPairs[0];
    }

    public void onReceive(Link link, byte[] data)
    {
        logger.dbg("Received data from link '", link, "' with ", data.length, " many bytes");

        Message recvMesg;
        if(Message.decode(data, recvMesg))
        {
            logger.dbg("Received from link '", link, "' message: ", recvMesg);

            // Process message
            MType mType = recvMesg.getType();
            switch(mType)
            {
                // Handle ADV messages
                case MType.ADV:
                    handle_ADV(link, recvMesg);
                    break;
                default:
                    logger.warn("Unsupported message type: '", mType, "'");
            }
        }
        else
        {
            logger.warn("Received message from '", link, "' but failed to decode");
        }
    }

    private void dumpRoutes()
    {
        import std.stdio : writeln;

        this.routesLock.lock();

        scope(exit)
        {
            this.routesLock.unlock();
        }
        
        writeln("| Destination          | isDirect | Via            | Link              |");
        writeln("|----------------------|----------|----------------|-------------------|");
        foreach(Route route; this.routes)
        {
            writeln("| "~route.destination()~"\t| "~to!(string)(route.isDirect())~"\t| "~route.gateway()~"\t| "~to!(string)(route.link()));
        }
    }

    private void installRoute(Route route)
    {
        this.routesLock.lock();

        scope(exit)
        {
            this.routesLock.unlock();
        }

        this.routes[route.destination()] = route;
    }

    // Handles all sort of advertisement messages
    private void handle_ADV(Link link, Message recvMesg)
    {
        Advertisement advMesg;
        if(recvMesg.decodeAs(advMesg))
        {
            if(advMesg.isAdvertisement())
            {
                string destAdv;
                if(advMesg.getDestination(destAdv))
                {
                    logger.dbg("Got advertisement for a host '", destAdv, "'");

                    // todo, extrat details and create route to install
                    string dest = destAdv;
                    Link on = link;
                    string via = advMesg.getOrigin();
                    Route nr = Route(dest, on, via);
                    installRoute(nr);
                }
            }
            else
            {
                logger.warn("We don't yet support ADV.RETRACTION");
            }
        }
        else
        {
            logger.warn("Received mesg marked as ADV but was not advertisemnt");
        }
    }

    private void installSelfRoute()
    {
        Route selfR = Route(getPublicKey(), null);
        installRoute(selfR);
    }

    private Route[] getRoutes()
    {
        this.routesLock.lock();

        scope(exit)
        {
            this.routesLock.unlock();
        }

        return this.routes.values.dup;
    }

    private void advertiseLoop()
    {
        while(true)
        {
            // advertise to all links
            Link[] selected = getLinkMan().getLinks();
            logger.info("Advertising to ", selected.length, " many links");
            foreach(Link link; selected)
            {

                // advertise each route in table
                foreach(Route route; getRoutes())
                {
                    logger.info("Advertising route '", route, "'");
                    string dst = route.destination();
                    string via = this.getPublicKey(); // routes must be advertised as if they're from me now

                    Advertisement advMesg = Advertisement.newAdvertisement(dst, via);
                    Message message;
                    if(toMessage(advMesg, message))
                    {
                        logger.dbg("Sending advertisement on '", link, "'...");
                        link.broadcast(message.encode()); // should have a return value for success or failure
                        logger.info("Sent advertisement");
                    }
                    else
                    {
                        // todo, handle failure to encode
                        logger.error("Failure to encode, developer error");
                    }
                }

                
            }

            Thread.sleep(this.advFreq);
        }
    }
}

version(unittest)
{
    import std.stdio;
    import core.thread : Thread;
    import core.sync.mutex : Mutex;
    import core.sync.condition : Condition;
    import std.conv : to;

    import twine.core.wire;

    public class AdvBouncerLink : Link
    {
        private Thread t;

        private byte[][] ingress;
        private Mutex ingressLock;
        private Condition ingressSig;

        private string srcAddr;
        private string hostToAdv;
        
        // takes in the the srcAddr to use
        // and also the dummy host to advertise
        // every now-and-then
        //
        // todo: shoudl be REALLY be testing the above
        // here and not with a router-to-router
        // test?
        this(string srcAddr, string hostToAdv)
        {
            this.t = new Thread(&listenerLoop);
            this.ingressLock = new Mutex();
            this.ingressSig = new Condition(this.ingressLock);
            this.srcAddr = srcAddr;
            this.hostToAdv = hostToAdv;
        }

        public override void transmit(byte[] dataIn, string to)
        {
            // not used
        }

        public override void broadcast(byte[] dataIn)
        {
            // on transmit lock, store, wake up, unlock
            this.ingressLock.lock();

            scope(exit)
            {
                this.ingressLock.unlock();
            }

            this.ingress ~= dataIn;
            this.ingressSig.notify();
        }

        public override string getAddress()
        {
            return this.srcAddr;
        }

        private void listenerLoop()
        {
            while(true)
            {
                // lock, wait, process, unlock
                this.ingressLock.lock();
                this.ingressSig.wait();

                scope(exit)
                {
                    this.ingress.length = 0;
                    this.ingressLock.unlock();
                }

                // process each advertisement
                foreach(byte[] dataIn; this.ingress)
                {
                    // decode
                    logger.dbg("AdvLink[", cast(void*)this, "]: received advertisement (presumably): ", dataIn);

                    Message message;
                    
                    if(Message.decode(dataIn, message) && message.getType() == MType.ADV)
                    {
                        Advertisement advMesg;
                        
                        if(message.decodeAs(advMesg))
                        {
                            logger.dbg("AdvLink: Incoming adv: ", advMesg);
                        }
                        else
                        {
                            // failure to decode
                        }
                    }
                    else
                    {
                        logger.error("Could not decode incoming message");
                    }

                }

                // also send advertisement of my own routes
                byte[] dataOut = cast(byte[])"ABBA"; // todo, implement (note: handling bad bytes FAILS without exception in msgpack-d)

                // route to advertise originates from ourselves as it is a self-route
                string dst = hostToAdv;
                string via = dst; // self-route
                Advertisement adv = Advertisement.newAdvertisement(dst, via);
                Message mesgOut;
                toMessage(adv, mesgOut);
                dataOut = mesgOut.encode();

                // Place resp into link's rx
                this.receive(dataOut);
            }
        }

        public void test_begin()
        {
            this.t.start();
        }

        public void test_end()
        {
            // todo, actually add a stop somewhere in the listenerLoop()
            this.t.join();
        }
    }
}

unittest
{
    // create and start router
    Router r = new Router();
    r.start();

    // hosts I want to send out during adverstiements
    string dummyHost1 = "hostB";
    string dummyHost2 = "hostC";

    // we add a few links which will respond
    // to advertisements in a coin-flip manner
    // and if so, then with a random delay
    //
    // I also provuide the src addresses of these links
    AdvBouncerLink l1 = new AdvBouncerLink("fe80:1::1", dummyHost1);
    AdvBouncerLink l2 = new AdvBouncerLink("fe80:2::1", dummyHost2);
    l1.test_begin(), l2.test_begin();
    r.getLinkMan().addLink(l1);
    r.getLinkMan().addLink(l2);



    // for info sake, dump the routing table every now
    // and then (make this a part of the router?)
    while(true)
    {
        r.dumpRoutes();
        Thread.sleep(dur!("seconds")(10));
    }

}




// todo, unittest with router-to-router-to-router testing