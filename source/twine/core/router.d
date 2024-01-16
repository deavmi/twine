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
import niknaks.functional : Optional;
import twine.core.arp;

// for data destined to yourself (todo, in future maybe have dest?)
public struct UserDataPkt
{
    private string src;
    private byte[] data;

    this(string src, byte[] data)
    {
        this.src = src;
        this.data = data;
    }

    public string getSrc()
    {
        return this.src;
    }

    public byte[] getPayload()
    {
        return this.data;
    }
}

import std.functional : toDelegate;
public alias DataCallbackDelegate = void delegate(UserDataPkt);

private void nopHandler(UserDataPkt u)
{
    logger.dbg("NOP handler: ", u);
    logger.dbg("NOP handler: ", cast(string)u.getPayload());
}

public class Router : Receiver
{
    private bool running;

    // todo, make use of this in the future with a message processing thread
    // offload, from on-link processing
    private struct ProcMesg
    {
        private Link link;
        private byte[] data;
        private string llSrcAddr;

        this(Link from, byte[] recv, string llSrcAddr)
        {
            this.link = from;
            this.data = recv;
            this.llSrcAddr = llSrcAddr;
        }

        public Link getLink()
        {
            return this.link;
        }

        public byte[] getData()
        {
            return this.data;
        }

        public string getLLSource()
        {
            return this.llSrcAddr;
        }
    }

    // link management
    private const LinkManager linkMan; // const, never should be changed besides during construction
    private Thread advThread;
    private Duration advFreq;
    private string[] keyPairs;

    // routing tables
    private Route[string] routes;
    private Mutex routesLock;

    // arp management
    private ArpManager arp;

    // incoming message handler
    private const DataCallbackDelegate messageHandler;

    this(string[] keyPairs, DataCallbackDelegate messageHandler = toDelegate(&nopHandler))
    {
        this.linkMan = new LinkManager(this);
        this.arp = new ArpManager();
        
        this.advThread = new Thread(&advertiseLoop);
        this.advFreq = dur!("seconds")(5);

        this.keyPairs = keyPairs;
        this.messageHandler = messageHandler;

        this.routesLock = new Mutex();

        // add self route
        installSelfRoute();
    }

    public void start()
    {
        this.running = true;
        this.advThread.start();
    }

    public void stop()
    {
        this.running = false;
        this.advThread.join();
        
        // destroy the arp manager to stop it
        destroy(this.arp);
    }

    public final LinkManager getLinkMan()
    {
        return cast(LinkManager)this.linkMan;
    }

    private string getPublicKey()
    {
        return this.keyPairs[0];
    }

    private void process(Link link, byte[] data, string srcAddr)
    {
        logger.dbg("Received data from link '", link, "' with ", data.length, " many bytes (llSrc: "~srcAddr~")");

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
                // Handle ARP requests
                case MType.ARP:
                    handle_ARP(link, srcAddr, recvMesg);
                    break;
                // Handle DATA messages
                case MType.DATA:
                    handle_DATA(link, srcAddr, recvMesg);
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

    private bool isForwarding = true; // todo, make togglable during runtime

    private void attemptForward(Data dataPkt)
    {
        // lookup route to host
        string to = dataPkt.getDst();
        Optional!(Route) route = findRoute(to);

        // found route
        if(route.isPresent())
        {
            Route ro = route.get();

            // get the next-hop's link-layer address
            Optional!(ArpEntry) ae = arp.resolve(ro.gateway(), ro.link());
            
            // found arp entry for gateway
            if(ae.isPresent())
            {
                // get link-layer address of next-hop
                string via_ll = ae.get().llAddr();

                Message mesgOut;
                if(toMessage(dataPkt, mesgOut))
                {
                    ro.link().transmit(mesgOut.encode(), via_ll);
                    logger.dbg("forwarded to nexthop at lladdr '", via_ll, "'");
                }
                else
                {
                    logger.error("Data encode failed when attempting forwarding");
                }
            }
            // not found
            else
            {
                logger.error("Could not forward data packet '", dataPkt, "' via gateway '", ro.gateway(), "' as arp failed");
            }
        }
        // route not found
        else
        {
            logger.error("no route to host '"~to~"', cannot send");
        }
    }

    private void handle_DATA(Link link, string srcAddr, Message recvMesg)
    {
        Data dataPkt;
        if(recvMesg.decodeAs(dataPkt))
        {
            string uSrc = dataPkt.getSrc();
            string uDst = dataPkt.getDst();
            byte[] payload = dataPkt.getPayload();

            // if packet is destined to me
            if(uDst == getPublicKey())
            {
                logger.dbg("packet '", dataPkt, "' is destined to me");

                // run handler
                messageHandler(UserDataPkt(uSrc, payload));
            }
            // else, if forwarding enabled then forward
            else if(isForwarding)
            {
                attemptForward(dataPkt);
            }
            // niks
            else
            {
                logger.warn("Received packet '", dataPkt, "' which not destined to me, but forwarding is disabled");
            }
        }
        else
        {
            logger.warn("Received mesg marked as ARP but was not arp actually");
        }
    }

    private void handle_ARP(Link link, string srcAddr, Message recvMesg)
    {
        Arp arpMesg;
        if(recvMesg.decodeAs(arpMesg))
        {
            if(arpMesg.isRequest())
            {
                string requestedL3Addr;
                if(arpMesg.getRequestedL3(requestedL3Addr))
                {
                    logger.dbg("Got ARP request for L3-addr '", requestedL3Addr, "'");

                    // only answer if the l3 matches mine (I won't do the dirty work of others)
                    if(requestedL3Addr == getPublicKey())
                    {
                        Arp arpRep;
                        if(arpMesg.makeResponse(link.getAddress(), arpRep))
                        {
                            Message mesgOut;
                            if(toMessage(arpRep, mesgOut))
                            {
                                link.transmit(mesgOut.encode(), srcAddr);
                            }
                            else
                            {
                                logger.error("failure to encode message out for arp response");
                            }
                        }
                        else
                        {
                            logger.error("failure to generate arp response message");
                        }
                    }
                    // todo, hehe - proxy arp lookup?!?!?!?! unless
                    else
                    {
                        logger.dbg("I won't answer ARP request for l3 addr which does not match mine: '"~requestedL3Addr~"' != '"~getPublicKey()~"'");
                    }
                }
            }
            else
            {
                logger.warn("Someone sent you an ARP response, that's retarded - router discards, arp manager would pick it up");
            }
        }
        else
        {
            logger.warn("Received mesg marked as ARP but was not arp actually");
        }
    }

    public void onReceive(Link link, byte[] data, string srcAddr)
    {
        process(link, data, srcAddr);
    }

    public bool sendData(byte[] payload, string to)
    {
        // lookup route to host
        Optional!(Route) route = findRoute(to);

        // found route
        if(route.isPresent())
        {
            // construct data packet to send
            Data dataPkt; // todo, if any crypto it would be with `to` NOT `via` (which is imply the next hop)
            if(!Data.makeDataPacket(getPublicKey(), to, payload, dataPkt))
            {
                logger.dbg("data packet encoding failed");
                return false;
            }

            // encode
            Message mesgOut;
            if(!toMessage(dataPkt, mesgOut))
            {
                logger.dbg("encode error");
                return false;
            }

            Route r = route.get();

            // is data to self
            if(r.isSelfRoute())
            {
                // get the link and place reception on it
                r.link().receive(mesgOut.encode(), to);

                return true;
            }
            // to someone else
            else
            {
                // resolve link-layer address of next hop
                Optional!(ArpEntry) ae = this.arp.resolve(r.gateway(), r.link());

                if(ae.isPresent())
                {
                    // transmit over link to the destination ll-addr (as indiacted by arp)
                    r.link().transmit(mesgOut.encode(), ae.get().llAddr());
                    return true;
                }
                else
                {
                    logger.error("ARP failed for next hop '", r.gateway(), "' when sending to dst '"~r.destination()~"'");
                    return false;
                }
            }
        }
        // route not found
        else
        {
            logger.error("no route to host '"~to~"', cannot send");
            return false;
        }
    }

    /** 
     * Finds a route for the given destination
     * and returns it in the form of an optional
     *
     * Params:
     *   destination = the destination
     * Returns: an `Optional!(Route)`
     */
    public Optional!(Route) findRoute(string destination)
    {
        Optional!(Route) opt;

        Route ro;
        if(findRoute(destination, ro))
        {
            opt.set(ro);
        }

        return opt;
    }

    /** 
     * Finds a route for the given destination
     *
     * Params:
     *   destination = 
     *   ro = the found route is placed here
     * (if found)
     * Returns: `true` if a matching route was
     * found, otherwise `false`
     */
    private bool findRoute(string destination, ref Route ro)
    {
        this.routesLock.lock();

        scope(exit)
        {
            this.routesLock.unlock();
        }

        foreach(Route co; this.routes)
        {
            if(co.destination() == destination)
            {
                ro = co;
                return true;
            }
        }

        return false;
    }

    public void dumpRoutes()
    {
        import std.stdio : writeln;

        this.routesLock.lock();

        scope(exit)
        {
            this.routesLock.unlock();
        }
        
        writeln("| Destination          | isDirect | Via            | Link              | Distance |");
        writeln("|----------------------|----------|----------------|-------------------|----------|");
        foreach(Route route; this.routes)
        {
            // fixme, we are deadlocking ore blocking forever (probs deadlocking) on route.link() here
            writeln("| "~route.destination()~"\t| "~to!(string)(route.isDirect())~"\t| "~route.gateway()~"\t| "~to!(string)(route.link())~"\t| "~to!(string)(route.distance())~" |");
        }
    }

    private void installRoute(Route route)
    {
        this.routesLock.lock();

        scope(exit)
        {
            this.routesLock.unlock();
        }

        Route* cr = route.destination() in this.routes;

        // if no such route installs, go ahead and install it
        if(cr is null)
        {
            this.routes[route.destination()] = route;
        }
        // if such a route exists, then only install it if it
        // has a smaller distance than the current route
        else
        {
            if(route.distance() < (*cr).distance())
            {
                this.routes[route.destination()] = route;
            }
        }
    }

    // Handles all sort of advertisement messages
    private void handle_ADV(Link link, Message recvMesg)
    {
        Advertisement advMesg;
        if(recvMesg.decodeAs(advMesg))
        {
            if(advMesg.isAdvertisement())
            {
                RouteAdvertisement ra;
                if(advMesg.getAdvertisement(ra))
                {
                    logger.dbg("Got advertisement for a host '", ra, "'");

                    // todo, extrat details and create route to install
                    string dest = ra.getAddr();
                    Link on = link;
                    string via = advMesg.getOrigin();
                    ubyte distance = cast(ubyte)(ra.getDistance()+64); // new distance should be +64'd
                    Route nr = Route(dest, on, via, distance);

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
        Route selfR = Route(getPublicKey(), null, 0);
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

    /** 
     * Sends out modified routes from the routing
     * table (with us as the `via`) on an interval
     * whilst we are running
     */
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
                    ubyte distance = route.distance();

                    Advertisement advMesg = Advertisement.newAdvertisement(dst, via, distance);
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

    import niknaks.debugging : dumpArray;
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
                foundEndpoint.receive(dataIn, getAddress());
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



    writeln(dumpArray!(r1_routes));
    writeln(dumpArray!(r2_routes));
}


/**
 * Host (p1) --- Host (p2)
 * Host (p1) --- Host (p3)
 */
unittest
{
    PipedLink p1_to_p2 = new PipedLink("p1_2:addr");
    PipedLink p2_to_p1 = new PipedLink("p2:addr");

    p1_to_p2.connect(p2_to_p1, p2_to_p1.getAddress());
    p2_to_p1.connect(p1_to_p2, p1_to_p2.getAddress());

    

    PipedLink p1_to_p3 = new PipedLink("p1_3:addr");
    PipedLink p3_to_p1 = new PipedLink("p3:addr");

    p1_to_p3.connect(p3_to_p1, p3_to_p1.getAddress());
    p3_to_p1.connect(p1_to_p3, p1_to_p3.getAddress());

    

    


    Router r1 = new Router(["p1Pub", "p1Priv"]);
    r1.getLinkMan().addLink(p1_to_p2);
    r1.getLinkMan().addLink(p1_to_p3);
    r1.start();

    Router r2 = new Router(["p2Pub", "p2Priv"]);
    r2.getLinkMan().addLink(p2_to_p1);
    r2.start();

    Router r3 = new Router(["p3Pub", "p3Priv"]);
    r3.getLinkMan().addLink(p3_to_p1);
    r3.start();

    scope(exit)
    {
        r1.stop();
        r2.stop();
        r3.stop();
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

        writeln("<<<<<<<<<< r3 routes >>>>>>>>>>");
        r3.dumpRoutes();

        Thread.sleep(dur!("seconds")(2));
        cycleCnt++;
    }

    Route[] r1_routes = r1.getRoutes();
    Route[] r2_routes = r2.getRoutes();
    Route[] r3_routes = r3.getRoutes();

    writeln(dumpArray!(r1_routes));
    writeln(dumpArray!(r2_routes));
    writeln(dumpArray!(r3_routes));

    // r1 -> r2 (on-link forwarding decision)
    assert(r1.sendData(cast(byte[])"ABBA poespoes", "p2Pub"));
    // todo, check reception

    // r3 -> r2 (forwarded via r1)
    assert(r3.sendData(cast(byte[])"ABBA naainaai", "p2Pub"));
    // todo, check reception

    // todo, self send
    // todo, check reception

    // todo, check routes here
}