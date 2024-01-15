module twine.core.arp;

import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import niknaks.containers;
import twine.links.link : Link, Receiver;
import twine.core.wire;
import twine.logging;
import niknaks.functional : Optional;

private struct Target
{
    private string networkAddr;
    private Link onLink;

    this(string networkAddr, Link link)
    {
        this.networkAddr = networkAddr;
        this.onLink = link;
    }

    public string getAddr()
    {
        return this.networkAddr;
    }

    public Link getLink()
    {
        return this.onLink;
    }
}

public class ArpManager : Receiver
{
    private Mutex waitLock;
    private Condition waitSig;

    private Duration timeout = dur!("seconds")(5); // todo, configurabel

    private CacheMap!(Target, ArpEntry) table;

    this(Duration sweepInterval = dur!("seconds")(60))
    {
        this.table = new CacheMap!(Target, ArpEntry)(&regen, sweepInterval);

        this.waitLock = new Mutex();
        this.waitSig = new Condition(this.waitLock);
    }

    /** 
     * Attempts to resolve the link-layer address of
     * the provided layer-3 address over the provided
     * link.
     *
     * On success stroing the resulting `ArpEntry`
     * in the third parameter
     *
     * Params:
     *   networkAddr = the layer-3 address to resolve
     * by
     *   onLink = the `Link` to resolve over
     *   entry = resulting entry
     * Returns: `true` if resolution succeeded, `false`
     * otherwise (the `entry` is left untouched)
     */
    private bool resolve(string networkAddr, Link onLink, ref ArpEntry entry)
    {
        ArpEntry resolvedEntry = this.table.get(Target(networkAddr, onLink));

        // resolution failed if entry is empty
        if(resolvedEntry.isEmpty())
        {
            return false;
        }
        // else, succeeded, set and return
        else
        {
            entry = resolvedEntry;
            return true;
        }
    }
    
    /** 
     * Attempts to resolve the link-layer address of
     * the provided layer-3 address over the provided
     * link returning an optional as the result.
     *
     * Params:
     *   networkAddr = the layer-3 address to resolve
     * by
     *   onLink = the `Link` to resolve over
     * Returns: an `Optional!(ArpEntry)`
     */
    public Optional!(ArpEntry) resolve(string networkAddr, Link onLink)
    {
        Optional!(ArpEntry) opt;
        ArpEntry resolvedEntry;

        // if succeeded resolution
        if(resolve(networkAddr, onLink, resolvedEntry))
        {
            opt.set(resolvedEntry);
        }

        return opt;
    }

    /** 
     * Upon expiration this method is called to
     * regenerate a `Target`. This will do
     * an `ArpRequest` in order to fill up
     * the requested entry
     *
     * Params:
     *   target = the key to refresh for
     * Returns: an `ArpEntry`
     */
    private ArpEntry regen(Target target)
    {
        // use this link
        Link link = target.getLink();

        // address we want to resolve
        string addr = target.getAddr();

        // attach as a receiver to this link
        link.attachReceiver(this);

        logger.dbg("attach done");

        // todo, send request
        Arp arpReq = Arp.newRequest(addr);
        Message msg;
        if(toMessage(arpReq, msg))
        {
            link.broadcast(msg.encode());
            logger.dbg("arp req sent");
        }
        else
        {
            logger.error("Arp failed but oh boy, at the encoding level");
        }

        // wait for reply
        string llAddr;
        bool status = waitForLLAddr(addr, llAddr);

        // if timed out
        if(!status)
        {
            logger.warn("Arp failed for target: ", target);
            return ArpEntry.empty();
        }
        // on success
        else
        {
            ArpEntry arpEntry = ArpEntry(addr, llAddr);
            logger.info("Arp request completed: ", arpEntry);
            return arpEntry;
        }
    }

    // map l3Addr -> llAddr
    private string[string] addrIncome;

    private bool waitForLLAddr(string l3Addr, ref string llAddrOut)
    {
        StopWatch timer = StopWatch(AutoStart.yes);

        // todo, make timeout-able (todo, make configurable)
        while(timer.peek() < this.timeout)
        {
            this.waitLock.lock();

            scope(exit)
            {
                this.waitLock.unlock();
            }

            this.waitSig.wait(dur!("msecs")(500)); // todo, duty cycle if missed notify but also helps with checking for the timeout

            // scan if we have it
            string* llAddr = l3Addr in this.addrIncome;
            if(llAddr !is null)
            {
                string llAddrRet = *llAddr;
                this.addrIncome.remove(l3Addr);
                llAddrOut = llAddrRet; // set result
                return true; // did not timeout
            }
        }

        return false; // timed out
    }

    private void placeLLAddr(string l3Addr, string llAddr)
    {
        this.waitLock.lock();

        scope(exit)
        {
            this.waitLock.unlock();
        }

        this.waitSig.notify(); // todo, more than one or never?

        this.addrIncome[l3Addr] = llAddr;
    }

    public override void onReceive(Link src, byte[] data, string srcAddr)
    {
        Message recvMesg;
        if(Message.decode(data, recvMesg))
        {
            // payload type
            if(recvMesg.getType() == MType.ARP)
            {
                Arp arpMesg;
                if(recvMesg.decodeAs(arpMesg))
                {
                    ArpReply reply;
                    if(arpMesg.getReply(reply))
                    {
                        logger.info("ArpReply: ", reply);

                        // place and wakeup waiters
                        placeLLAddr(reply.networkAddr(), reply.llAddr());
                    }
                    else
                    {
                        logger.warn("Could not decode ArpReply");
                    }
                }
                else
                {
                    logger.warn("Message indicated it was ARP, but contents say otherwise");
                }
            }
            else
            {
                logger.dbg("Ignoring non-ARP related message");
            }
        }
        else
        {
            logger.warn("Failed to decode incoming message");
        }
    }
    
    ~this()
    {
        // todo, double check but yes this should be fine, I believe I added checks for this?
        // as in what if another thread is trying to resolve and we use this? how does
        // the regeneration function treat it
        destroy(this.table);
    }

    // todo, how to activate?
    public void test_stop()
    {
        destroy(this.table);
    }
}

import std.datetime.stopwatch : StopWatch, AutoStart;
import std.datetime : Duration, dur;


public struct ArpEntry
{
    private string l3Addr;
    private string l2Addr;

    this(string networkAddr, string llAddr)
    {
        this.l3Addr = networkAddr;
        this.l2Addr = llAddr;
    }

    public string networkAddr()
    {
        return this.l3Addr;
    }

    public string llAddr()
    {
        return this.l2Addr;
    }

    public bool isEmpty()
    {
        return this.l3Addr == "" && this.l2Addr == "";
    }

    public static ArpEntry empty()
    {
        return ArpEntry("", "");
    }
}

version(unittest)
{
    import twine.links.link;
    import std.stdio;
    import core.thread : Thread;
    import core.sync.mutex : Mutex;
    import core.sync.condition : Condition;
    import std.conv : to;

    // a dummy link which will respond with
    // arp replies using the provided map
    // of l3Addr -> l2Addr
    public class ArpRespondingLink : Link
    {
        private Thread t;
        private bool running;

        private byte[][] ingress;
        private Mutex ingressLock;
        private Condition ingressSig;

        private string[string] mappings;

        this(string[string] mappings)
        {
            this.t = new Thread(&listenerLoop);
            this.ingressLock = new Mutex();
            this.ingressSig = new Condition(this.ingressLock);
            this.mappings = mappings;

            this.running = true;
            this.t.start();
        }

        public override string getAddress()
        {
            // not used
            return null;
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

        private void listenerLoop()
        {
            while(this.running)
            {
                // lock, wait, process, unlock
                this.ingressLock.lock();
                this.ingressSig.wait(dur!("seconds")(1)); //todo, duty cycle
                logger.dbg("ArpRespondingLink waked, with ", this.ingress.length, " many packets");

                scope(exit)
                {
                    this.ingress.length = 0;
                    this.ingressLock.unlock();
                }

                // process each incoming message
                // but only if they are ARP requests
                foreach(byte[] dataIn; this.ingress)
                {
                    Message msg;
                    if(Message.decode(dataIn, msg))
                    {
                        if(msg.getType() == MType.ARP)
                        {
                            Arp arpMsg;
                            logger.dbg("here");
                            logger.dbg(msg);
                            if(msg.decodeAs(arpMsg))
                            {
                                
                                if(arpMsg.isRequest())
                                {
                                    string l3Addr_requested;
                                    if(arpMsg.getRequestedL3(l3Addr_requested))
                                    {
                                        // if we have a mapping for that
                                        if((l3Addr_requested in this.mappings) !is null)
                                        {
                                            string l2Addr_found = this.mappings[l3Addr_requested];

                                            Arp arpRep;
                                            if(arpMsg.makeResponse(l2Addr_found, arpRep))
                                            {
                                                Message msgRep;
                                                if(toMessage(arpRep, msgRep))
                                                {
                                                    logger.dbg("placing a fake arp reply to receiver");
                                                    receive(msgRep.encode(), l2Addr_found);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        public void stop()
        {
            this.running = false;

            this.ingressLock.lock();

            scope(exit)
            {
                this.ingressLock.unlock();
            }

            this.ingressSig.notify();
        }
    }
}

/**
 * This tests the `ArpManager`'s ability
 * to handle arp requests and responses
 *
 * We make use of a dummy `Link` which
 * we provide with mappings of layer 3
 * to layer 2 addresses such that when
 * an ARP request comes in we can respond
 * with the relevant details as such
 */
unittest
{
    // Map some layer 3 -> layer 2 addresses
    string[string] mappings;
    mappings["hostA:l3"] = "hostA:l2";
    mappings["hostB:l3"] = "hostB:l2";

    // create a dummy link that responds with those mappings
    ArpRespondingLink dummyLink = new ArpRespondingLink(mappings);

    ArpManager man = new ArpManager();

    // try resolve address `hostA:l3` over the `dummyLink` link (should PASS)
    Optional!(ArpEntry) entry = man.resolve("hostA:l3", dummyLink);
    assert(entry.isPresent());
    assert(entry.get().llAddr() == mappings["hostA:l3"]);

    // try resolve address `hostB:l3` over the `dummyLink` link (should PASS)
    entry = man.resolve("hostB:l3", dummyLink);
    assert(entry.isPresent());
    assert(entry.get().llAddr() == mappings["hostB:l3"]);

    // try top resolve `hostC:l3` over the `dummyLink` link (should FAIL)
    entry = man.resolve("hostC:l3", dummyLink);
    assert(entry.isPresent() == false);

    // shutdown the dummy link to get the unittest to end
    dummyLink.stop();

    // shutdown the arp manager
    // man.test_stop();

    destroy(man);
}