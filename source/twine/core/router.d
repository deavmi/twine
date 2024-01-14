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
import core.sync.condition : Condition;

public class Router : Receiver
{
    private bool running;

    private struct ProcMesg
    {
        private Link link;
        private byte[] data;

        this(Link from, byte[] recv)
        {
            this.link = from;
            this.data = recv;
        }

        public Link getLink()
        {
            return this.link;
        }

        public byte[] getData()
        {
            return this.data;
        }
    }

    private ProcMesg[] msgProcQueue;
    private Thread msgProcThread;
    private Mutex msgProcLock;
    private Condition msgProcSig;

    private const LinkManager linkMan; // const, never should be changed besides during construction
    private Thread advThread;
    private Duration advFreq;
    private string[] keyPairs;

    // routing tables
    private Route[string] routes;
    private Mutex routesLock;

    this(string[] keyPairs)
    {
        this.linkMan = new LinkManager(this);
        
        this.advThread = new Thread(&advertiseLoop);
        this.advFreq = dur!("seconds")(5);

        this.msgProcThread = new Thread(&processLoop);
        this.msgProcLock = new Mutex();
        this.msgProcSig = new Condition(this.msgProcLock);

        this.keyPairs = keyPairs; // todo, accepts as arguments

        this.routesLock = new Mutex();

        // add self route
        installSelfRoute();
    }

    public void start()
    {
        this.running = true;
        this.advThread.start();
        // this.msgProcThread.start();
    }

    public void stop()
    {
        this.running = false;
        this.advThread.join();
        
        // stop_msgProc();
    }

    private void stop_msgProc()
    {
        this.msgProcLock.lock();
        this.msgProcSig.notify();
        this.msgProcLock.unlock();

        this.msgProcThread.join();
    }

    public final LinkManager getLinkMan()
    {
        return cast(LinkManager)this.linkMan;
    }

    private string getPublicKey()
    {
        return this.keyPairs[0];
    }

    private void processLoop()
    {
        while(this.running)
        {
            this.msgProcLock.lock();

            scope(exit)
            {
                this.msgProcLock.unlock();
            }

            this.msgProcSig.wait();

            // process each message
            foreach(ProcMesg m; this.msgProcQueue)
            {
                process(m.getLink(), m.getData());
            }

            // clear all
            this.msgProcQueue.length = 0;
        }
    }

    private void process(Link link, byte[] data)
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

    public void onReceive(Link link, byte[] data)
    {
        // this.msgProcLock.lock();

        // scope(exit)
        // {
        //     this.msgProcLock.unlock();
        // }

        // // append to message queue and wake up
        // this.msgProcQueue ~= ProcMesg(link, data);
        // this.msgProcSig.notify();

        process(link, data);
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
            // fixme, we are deadlocking ore blocking forever (probs deadlocking) on route.link() here
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

                    // never install over self-route
                    if(nr.destination() != getPublicKey())
                    {
                        installRoute(nr);
                    }
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
        while(this.running)
        {
            // advertise to all links
            Link[] selected = getLinkMan().getLinks();
            logger.info("Advertising to ", selected.length, " many links");
            foreach(Link link; selected)
            {
                logger.dbg("hey1, link iter: ", link);

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
}

version(unittest)
{
    /** 
     * A `Link` which can have several other
     * links attached to it as reachable
     * interfaces
     */
    public class PipedLink : Link
    {
        private Link[string] endpoints;
        private Mutex endpointsLock;
        private Condition endpointsSig;

        private string myAddress;

        this(string myAddress)
        {
            this.myAddress = myAddress;
            this.endpointsLock = new Mutex();
            this.endpointsSig = new Condition(this.endpointsLock);
        }

        public void connect(Link link, string addr)
        {
            this.endpointsLock.lock();

            scope(exit)
            {
                this.endpointsLock.unlock();
            }

            this.endpoints[addr] = link;
        }

        public void disconnect(string addr)
        {
            this.endpointsLock.lock();

            scope(exit)
            {
                this.endpointsLock.unlock();
            }

            this.endpoints.remove(addr);
        }

        // delivers the data to the given attached endpoint (if it exists)
        public override void transmit(byte[] dataIn, string to)
        {
            this.endpointsLock.lock();

            scope(exit)
            {
                this.endpointsLock.unlock();
            }

            Link* foundEndpoint = to in this.endpoints;
            if(foundEndpoint !is null)
            {
                foundEndpoint.receive(dataIn);
            }
        }

        // delivers the data to all attached endpoints
        public override void broadcast(byte[] dataIn)
        {
            this.endpointsLock.lock();

            scope(exit)
            {
                this.endpointsLock.unlock();
            }

            foreach(string dst; this.endpoints.keys())
            {
                transmit(dataIn, dst);
            }
        }

        public override string getAddress()
        {
            return this.myAddress;
        }
    }
}

/**
 * We have the following topology:
 *
 * [ Host (p1) ] --> (p2)
 * [ Host (p2) ] --> (p1)
 *
 * We test that both receives
 * each other's self-routes
 * in this test. After which,
 * we shut the routers down.
 */
unittest
{
    PipedLink p1 = new PipedLink("p1:addr");
    PipedLink p2 = new PipedLink("p2:addr");

    p1.connect(p2, p2.getAddress());
    p2.connect(p1, p1.getAddress());


    Router r1 = new Router(["p1Pub", "p1Priv"]);
    r1.getLinkMan().addLink(p1);
    r1.start();

    Router r2 = new Router(["p2Pub", "p2Priv"]);
    r2.getLinkMan().addLink(p2);
    r2.start();

    // on assertion failure, try stop everything
    scope(exit)
    {
        // stop routers
        r1.stop();
        r2.stop();
    }


    // todo, please do assertions on routes for the
    // sake of testing
    size_t cyclesMax = 10;
    size_t cycleCnt = 0;
    while(cycleCnt < cyclesMax)
    {
        writeln("<<<<<<<<<< r1 routes >>>>>>>>>>");
        r1.dumpRoutes();

        writeln("<<<<<<<<<< r2 routes >>>>>>>>>>");
        r2.dumpRoutes();

        Thread.sleep(dur!("seconds")(2));
        cycleCnt++;
    }

    // get routes from both and check that both are 2-many
    Route[] r1_routes = r1.getRoutes();
    Route[] r2_routes = r2.getRoutes();
    assert(r1_routes.length == 2);
    assert(r2_routes.length == 2);

    // ensure that we can find router 1's self-route
    // and route to router 2
    Route foundR1_selfRoute;
    Route foundR1_R2route;
    foreach(Route r; r1_routes)
    {
        if(r.destination() == r1.getPublicKey())
        {
            foundR1_selfRoute = r;
        }
        else
        {
            foundR1_R2route = r;
        }
    }
    assert(foundR1_selfRoute.destination() == r1.getPublicKey());
    assert(foundR1_R2route.destination() == r2.getPublicKey());

    // ensure that we can find router 2's self-route
    // and route to router 1
    Route foundR2_selfRoute;
    Route foundR2_R1route;
    foreach(Route r; r2_routes)
    {
        if(r.destination() == r2.getPublicKey())
        {
            foundR2_selfRoute = r;
        }
        else
        {
            foundR2_R1route = r;
        }
    }
    assert(foundR2_selfRoute.destination() == r2.getPublicKey());
    assert(foundR2_R1route.destination() == r1.getPublicKey());



    writeln(r1_routes);
    writeln(r2_routes);

    


}