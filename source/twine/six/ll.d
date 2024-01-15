module twine.six.ll;

import core.thread;
import twine.links.link;
import std.socket : Socket, Address, parseAddress, AddressFamily, SocketType, ProtocolType;
import std.socket : SocketFlags, MSG_TRUNC, MSG_PEEK;
import std.stdio;

public class LLInterface : Link
{
    private const Address mcastAddress;
    private Socket mcastSock; // make const
    private Thread mcastThread;

    private Address peerAddress;
    private Socket peerSock; // make const
    private Thread peerThread;

    this(string interfaceName, string mcastAddr = "ff02::1", ushort mcastPort = 1024) // should latter two be configurable?
    {
        // Multicast socket for discovery
        this.mcastAddress = parseAddress(mcastAddr~"%"~interfaceName, mcastPort);
        this.mcastSock = new Socket(AddressFamily.INET6, SocketType.DGRAM, ProtocolType.UDP);
        this.mcastSock.bind(cast(Address)this.mcastAddress); // todo, defer to later?

        // Multicast thread
        this.mcastThread = new Thread(&mcastLoop);
        this.mcastThread.start();

        // Peering socket for transit
        this.peerAddress = parseAddress("::", 0); // todo, query interface addresses using getaddrinfo or something
                                                  // in order to derive the link-local address of this host
        writeln(this.peerAddress);        
        this.peerSock = new Socket(AddressFamily.INET6, SocketType.DGRAM, ProtocolType.UDP);
        this.peerSock.bind(cast(Address)this.peerAddress); // todo, defer to later?
        writeln(this.peerSock.localAddress());

        // Peering thread
        this.peerThread = new Thread(&peerLoop);
        this.peerThread.start();
    }

    public override string getAddress()
    {
        return this.peerAddress.toString();
    }

    public override void transmit(byte[] xmit, string addr)
    {
        // we could send via any socket probably, just destination address is iportant
        this.mcastSock.sendTo(xmit, parseAddress(addr));
    }

    public override void broadcast(byte[] xmit)
    {
        this.mcastSock.sendTo(xmit, cast(Address)this.mcastAddress);
    }

    private void mcastLoop()
    {
        while(true) // todo flag
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
                Address fromAddr; // todo, do we need this?

                buffer.length = cnt;
                this.mcastSock.receiveFrom(buffer, fromAddr);
                writeln("from: ", fromAddr, "bytes: ", buffer);

                // Pass received data on upwards
                receive(buffer); // todo, pass in fromAddr
            }
        }
    }

    private void peerLoop()
    {
        while(true) // todo flag
        {
            byte[] buffer;

            // this.socket.receiveFrom(buffer, SocketFlags.PEEK|)
            Thread.sleep(dur!("seconds")(100)); 
        }
    }

}