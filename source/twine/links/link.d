module twine.links.link;

import core.sync.mutex : Mutex;
import std.container.slist : SList;
import std.range : walkLength;
import std.conv : to;

// A link could be a dumy link (for testing)
// or a real link (using libtun for example)
public abstract class Link
{
    private SList!(Receiver) receivers;
    private Mutex receiverLock;

    this()
    {
        this.receiverLock = new Mutex();
    }
    
    // A link driver must call this when it
    // has new data
    public final void receive(byte[] recv)
    {
        this.receiverLock.lock();

        scope(exit)
        {
            this.receiverLock.unlock();
        }

        foreach(Receiver endpoint; this.receivers)
        {
            endpoint.onReceive(this, recv);
        }
    }

    private final auto getRecvCnt()
    {
        this.receiverLock.lock();

        scope(exit)
        {
            this.receiverLock.unlock();
        }

        return walkLength(this.receivers[]);
    }

    public final void attachReceiver(Receiver receiver)
    {
        this.receiverLock.lock();

        scope(exit)
        {
            this.receiverLock.unlock();
        }

        // don't add if already present
        foreach(Receiver cr; this.receivers[])
        {
            if(cr is receiver)
            {
                return;
            }
        }

        this.receivers.insertAfter(this.receivers[], receiver);
    }

    public final void removeReceiver(Receiver receiver)
    {
        this.receiverLock.lock();

        scope(exit)
        {
            this.receiverLock.unlock();
        }

        this.receivers.linearRemoveElement(receiver);
    }

    // Link-implementation specific for driver to send data
    // to a specific destination address
    public abstract void transmit(byte[] xmit, string addr);

    // Link-implementation spefici for driver to broadcast
    // to all hosts on its broadcast domain
    public abstract void broadcast(byte[] xmit);

    // Link-implementation specific for driver to report its address
    public abstract string getAddress();

    // shows the memory address, type and the number of attached receivers
    public override string toString()
    {
        import std.string : split;
        return split(this.classinfo.name, ".")[$-1]~" [id: "~to!(string)(cast(void*)this) ~", recvs: "~to!(string)(getRecvCnt())~"]";
    }
}

// A subscriber could be a router that wants
// to subscribe to data coming in from this
// interface
public interface Receiver
{
    public void onReceive(Link source, byte[] recv);
}


// DummyReceiver (safe for multiple receptions)
version(unittest)
{
    import std.stdio;

    public struct ReceivePack
    {
        public Link src;
        public byte[] data;
    }

    public class DummyReceiver : Receiver
    {
        private ReceivePack[] received;
        private Mutex lock;

        this()
        {
            this.lock = new Mutex();
        }

        public void onReceive(Link source, byte[] recv)
        {
            this.lock.lock();

            scope(exit)
            {
                this.lock.unlock();
            }

            writeln("DummyRecv [link: '", source, ", data: ", recv, "]");
            this.received ~= ReceivePack(source, recv);
        }

        public ReceivePack[] getReceived()
        {
            this.lock.lock();

            scope(exit)
            {
                this.lock.unlock();
            }

            return this.received.dup;
        }
    }
}

// DummyLink
version(unittest)
{
    import std.stdio;

    import core.thread;

    public class DummyLink : Link
    {
        private Thread t;
        private size_t cycles;
        private Duration period;

        this(size_t cycles, Duration period = dur!("seconds")(1))
        {
            this.cycles = cycles;
            this.period = period;
            this.t = new Thread(&run);
        }

        this()
        {
            this(3);
        }

        private void run()
        {
            writeln("cycle enter");
            scope(exit)
            {
                writeln("cycle exit");
            }

            for(size_t i = 0; i < this.cycles; i++)
            {
                // todo, should be random data or something of our choosing
                writeln("cycle (", i, ")");
                test_deliver(cast(byte[])"ABBA");
                Thread.sleep(this.period);
            }            
        }

        public override void transmit(byte[])
        {
            // not used
        }

        public override string getAddress()
        {
            // not used
            return null;
        }

        public void test_deliver(byte[] data)
        {
            this.receive(data);
        }

        public void test_begin()
        {
            this.t.start();
        }

        public void test_waitForThreadFinish()
        {
            this.t.join();
        }
    }
}

unittest
{
    DummyReceiver r = new DummyReceiver();
    DummyLink d = new DummyLink();

    // attach a receiver firstly, then begin
    d.attachReceiver(r);
    d.test_begin();

    // todo, replace with something smarter or nah?
    d.test_waitForThreadFinish();

    // detach receiver from link, manually cause link
    // to deliver - we should not receive anything
    // more (see below - only 3 should be received)
    d.removeReceiver(r);
    d.test_deliver(cast(byte[])"ABBA");

    // check that the receiver received everything
    ReceivePack[] received = r.getReceived();
    assert(received.length == 3);

    // source should be link `d` and same data
    // on each delivery
    static foreach(i; 0..3)
    {
        assert(received[i].src == d);
        assert(received[i].data == [65, 66, 66, 65]);
    }
}