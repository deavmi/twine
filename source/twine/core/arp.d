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

        // todo, send request
        Arp arpReq = Arp.newRequest(addr);
        Message msg;
        if(toMessage(arpReq, msg))
        {
            link.broadcast(msg.encode());
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

            this.waitSig.wait();

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