module twine.six.ll;

import core.thread;
import twine.links.link;
import std.socket : Socket, Address, parseAddress, AddressFamily, SocketType, ProtocolType;
import std.socket : SocketFlags, MSG_TRUNC, MSG_PEEK;
import std.stdio;



import std.string : fromStringz;
import std.socket : Internet6Address;
import std.conv : to;

import twine.netd;

public class LLInterface : Link
{
    private const Address mcastAddress;
    private Socket mcastSock; // make const
    private Thread mcastThread;

    private Address peerAddress;
    private Socket peerSock; // make const
    private Thread peerThread;

    private bool running;
    private Duration wakeTime; // time to wake up to check if we should stop (todo, interrupt would be nice)

    private const InterfaceInfo if_;

    this(string interfaceName_, string mcastAddr = "ff02::1", ushort mcastPort = 1024) // should latter two be configurable?
    {
        // discover link-local addresses on the given interface
        InterfaceInfo[] linkLocalAddresses;
        if(!getLinkLocalOf(interfaceName_, linkLocalAddresses))
        {
            // todo, add early exit with exception
            throw new Exception("Failed to check for link-local addresses for interface '"~interfaceName_~"'"); // todo, twine exception
        }
        else if(linkLocalAddresses.length == 0)
        {
            // todo, handle case of no link local
            throw new Exception("Interface '"~interfaceName_~"' has no link-local addresses"); // todo, twine exception
        }

        this.if_ = linkLocalAddresses[0];

        // Multicast socket for discovery
        this.mcastAddress = parseAddress(mcastAddr~"%"~if_.getName(), mcastPort);
        this.mcastSock = new Socket(AddressFamily.INET6, SocketType.DGRAM, ProtocolType.UDP);
        
        // Multicast thread
        this.mcastThread = new Thread(&mcastLoop);

        // Peering socket for transit
        this.peerAddress = parseAddress(if_.getAddress().toAddrString()~"%"~if_.getName(), 0); // todo, query interface addresses using getaddrinfo or something
                                                  // in order to derive the link-local address of this host      
        this.peerSock = new Socket(AddressFamily.INET6, SocketType.DGRAM, ProtocolType.UDP);
        
        // Peering thread
        this.peerThread = new Thread(&peerLoop);
        
        // todo, we start it on construction (for now)
        start();
    }

    public void start()
    {
        this.running = true;
        
        // Bind sockets
        this.mcastSock.bind(cast(Address)this.mcastAddress);
        this.peerSock.bind(cast(Address)this.peerAddress);
        writeln(this.peerSock.localAddress());

        // Start multicast thread
        this.mcastThread.start();

        // Start peering thread
        this.peerThread.start();
    }

    public override string getAddress()
    {
        import std.stdio;
        writeln("HHHA");
        writeln("HHHA");
        writeln("HHHA");
        writeln("HHHA");
        // we need the bound port (not the 0 from init)
        string port = this.peerSock.localAddress().toPortString();
        string ret = if_.getAddress().toAddrString()~":"~port;
        writeln("ret: ", ret);
        writeln("ret: ", ret);
        writeln("ret: ", ret);

        return ret;
    }

    public override string toString()
    {
        return "LLInterface [name: "~if_.getName()~", address: "~if_.getAddress().toAddrString()~", recvs: "~to!(string)(getRecvCnt())~"]";
    }

    private static Address getAddress_fromStringWithKak(string addr)
    {
        import std.string : split, lastIndexOf, strip;
        string[] cmps = addr.split(":");
        import std.conv : to;
        writeln(cmps);
        string host = strip(strip(addr[0..lastIndexOf(addr, ":")], "["), "]");
        writeln("host: ", host);
        ushort port = to!(ushort)(addr[lastIndexOf(addr, ":")+1..$]);
        writeln("port: ", port);

        return parseAddress(host, port);
    }

    public override void transmit(byte[] xmit, string addr)
    {
        import std.socket : SocketException;
        try
        {
            // we could send via any socket probably, just destination address is iportant
            writeln("transmit LLInterface to: "~addr);
            writeln("transmit LLInterface to (Address object): ", getAddress_fromStringWithKak(addr));
            auto i=this.peerSock.sendTo(xmit, getAddress_fromStringWithKak(addr));
            writeln("transmit LLInterface to: "~addr~" with return-no: ", i);
        }
        catch(SocketException e)
        {
            writeln("transmit failure: ", e);
        }
    }

    public override void broadcast(byte[] xmit)
    {
        writeln("heyo: broadcasting");
        auto i = this.peerSock.sendTo(xmit, cast(Address)this.mcastAddress);
        writeln("broadcast result: ", i);
    }

    private void mcastLoop()
    {
        while(this.running) // todo flag
        {
            byte[] buffer = [1];

            // + Return the length of datagram, not successfully read bytes
            // + Don't dequeue the datagram from the kernel's internal buffer
            SocketFlags firstReadFlags = cast(SocketFlags)(MSG_TRUNC|MSG_PEEK);
            ptrdiff_t cnt = this.mcastSock.receiveFrom(buffer, firstReadFlags);

            if(cnt <= 0)
            {
                // todo handle errors
                // 0 would not happen no dc
                // anything less maybe?
            }
            // Now dequeue the correct number of bytes
            else
            {
                Address fromAddr;

                buffer.length = cnt;
                this.mcastSock.receiveFrom(buffer, fromAddr);
                writeln("from: ", fromAddr, "bytes: ", buffer);

                // Pass received data on upwards
                receive(buffer, fromAddr.toString());
            }
        }
    }

    private void peerLoop()
    {
        while(this.running) // todo flag
        {
            byte[] buffer = [1];

            // + Return the length of datagram, not successfully read bytes
            // + Don't dequeue the datagram from the kernel's internal buffer
            SocketFlags firstReadFlags = cast(SocketFlags)(MSG_TRUNC|MSG_PEEK);
            ptrdiff_t cnt = this.peerSock.receiveFrom(buffer, firstReadFlags);

            if(cnt <= 0)
            {
                // todo handle errors
                // 0 would not happen no dc
                // anything less maybe?
            }
            // Now dequeue the correct number of bytes
            else
            {
                Address fromAddr;

                buffer.length = cnt;
                this.peerSock.receiveFrom(buffer, fromAddr);
                writeln("from: ", fromAddr, "bytes: ", buffer);

                // Pass received data on upwards
                receive(buffer, fromAddr.toString());
            }
        }
    }

    public void stop()
    {
        // todo, interrupt the thread here - I want to be able to do that
    }

}