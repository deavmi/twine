module twine.core.arp;

import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import niknaks.containers;
import twine.links.link : Link, Receiver;
import twine.core.wire;
import twine.logging;

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
    // private ArpEntry[string] table;
    // private Mutex tableLock; // todo, condvar to wake up on changes and maybe check expiration (cause why not)

    private Mutex waitLock;
    private Condition waitSig;

    private CacheMap!(Target, ArpEntry) table;

    this(Duration sweepInterval = dur!("seconds")(60))
    {
        this.table = new CacheMap!(Target, ArpEntry)(&regen, sweepInterval);

        this.waitLock = new Mutex();
        this.waitSig = new Condition(this.waitLock);
    }

    public ArpEntry resolve(string networkAddr, Link onLink)
    {
        return resolve(Target(networkAddr, onLink));
    }

    private ArpEntry resolve(Target target)
    {
        return this.table.get(target);
    }

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
            logger.error("Fok, encode error during regen(Target)");
        }

        // wait for reply (todo, add timer)
        string llAddr = waitForLLAddr(addr);
        ArpEntry arpEntry = ArpEntry(addr, llAddr);
        logger.info("Arp request completed: ", arpEntry);

        return arpEntry;
    }

    // map l3Addr -> llAddr
    private string[string] addrIncome;

    private string waitForLLAddr(string l3Addr)
    {
        // todo, make timeout-able
        while(true)
        {
            this.waitLock.lock();

            scope(exit)
            {
                this.waitLock.unlock();
            }

            this.waitSig.wait(); // todo, duty cycle if missed notify

            // scan if we have it
            string* llAddr = l3Addr in this.addrIncome;
            if(llAddr !is null)
            {
                string llAddrRet = *llAddr;
                this.addrIncome.remove(l3Addr);
                return llAddrRet;
            }
        }
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

    public override void onReceive(Link src, byte[] data)
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
                                        Arp arpRep;
                                        if(arpMsg.makeResponse(this.mappings[l3Addr_requested], arpRep))
                                        {
                                            Message msgRep;
                                            if(toMessage(arpRep, msgRep))
                                            {
                                                logger.dbg("placing a fake arp reply to receiver");
                                                receive(msgRep.encode());
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

unittest
{
    // Map some layer 3 -> layer 2 addresses
    string[string] mappings;
    mappings["hostA:l3"] = "hostA:l2";
    mappings["hostB:l3"] = "hostB:l2";

    // create a dummy link that responds with those mappings
    ArpRespondingLink dummyLink = new ArpRespondingLink(mappings);

    ArpManager man = new ArpManager();

    // try resolve address `hostA:l3` over the `dummyLink` link
    ArpEntry resolution = man.resolve("hostA:l3", dummyLink);
    assert(resolution.llAddr() == mappings["hostA:l3"]);

    // try resolve address `hostB:l3` over the `dummyLink` link
    resolution = man.resolve("hostB:l3", dummyLink);
    assert(resolution.llAddr() == mappings["hostB:l3"]);

    // shutdown the dummy link to get the unittest to end
    dummyLink.stop();

    // shutdown the arp manager
    man.test_stop();
}