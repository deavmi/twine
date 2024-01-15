module twine.six.ll;

import core.thread;
import twine.links.link;
import std.socket : Socket, Address, parseAddress, AddressFamily, SocketType, ProtocolType;
import std.socket : SocketFlags, MSG_TRUNC, MSG_PEEK;
import std.stdio;

import core.sys.posix.sys.socket : AF_INET6;
import twine.six.crap : getifaddrs, freeifaddrs, ifaddrs, sockaddr, sockaddr_in6, in6_addr, uint8_t;

import std.string : fromStringz;
import std.socket : Internet6Address;
import std.conv : to;

/** 
 * Determines if an IPv6 address is link-local
 *
 * Params:
 *   addr6 = the address (in big endian)
 * Returns: `true` if so, `false` otherwise
 */
private bool isLinkLocal(ubyte[16] addr6)
{
    return addr6[0] == 0xfe && addr6[1] == 0x80;
}

/**
 * Tests link-locality
 */
unittest
{
    assert(isLinkLocal([254, 128, 0, 0, 0, 0, 0, 0, 38, 56, 97, 106, 72, 146, 206, 225]));
    assert(!isLinkLocal([2, 1, 108, 86, 249, 213, 183, 165, 143, 66, 177, 171, 158, 14, 81, 105]));
}

public struct InterfaceInfo
{
    private const string name;
    private const Address address;

    this(string name, Address address)
    {
        this.name = name;
        this.address = address;
    }

    public string getName() const
    {
        return this.name;
    }

    public const(Address) getAddress() const
    {
        return this.address;
    }
}

// note, only does v6 and on link-local specifically
public bool determineInterfaceAddresses(ref InterfaceInfo[] interfaces)
{
    ifaddrs* interfaceAddresses;
    int stat = getifaddrs(&interfaceAddresses);
    if(stat == 0)
    {
        scope(exit)
        {
            // todo, free allocated things here
            freeifaddrs(interfaceAddresses);
        }

        do
        {
            writeln("ifa_ptr rn: ", cast(void*)interfaceAddresses);

            string interfaceName = cast(string)fromStringz(interfaceAddresses.ifa_name);
            writeln("name: "~interfaceName);

            sockaddr* sAddr = interfaceAddresses.ifa_addr;

            // sometimes, you may hit an `unspec` interface, then `if_addr` is 0
            writeln("socketaddr (ptr): ", cast(void*)sAddr);
            if(sAddr !is null)
            {
                // only want ipv6 (AF_6)
                if(sAddr.sa_family == AF_INET6)
                {
                    writeln("found a v6 interface!: ", interfaceName);

                    // cast to extended sub-object/struct
                    sockaddr_in6* s6Addr = cast(sockaddr_in6*)sAddr;

                    
                    writeln("scope id: ", s6Addr.sin6_scope_id);
                    // if(s6Addr.sin6_scope_id == 18 || true) // todo, this feels broke, might need to manually check addresses
                    
                    // obtain the 16 bytes (the contained element of in6_addr
                    // is a singular array of 16 ubytes), meaning we can cast
                    // direct on it
                    in6_addr addrBytesC = s6Addr.sin6_addr;
                    ubyte[16] arr = cast(ubyte[16])addrBytesC;
                    writeln(arr);

                    // only want to get da one which has la-link-local
                    if(isLinkLocal(arr))
                    {
                        writeln("Got a lekker linj-local");
                        Internet6Address linkLocalAddr = new Internet6Address(arr, 0);

                        interfaces ~= InterfaceInfo(interfaceName, linkLocalAddr);
                    }
                    
                }
            }

            // Move to next interface info struct
            interfaceAddresses = interfaceAddresses.ifa_next;
        }
        while(interfaceAddresses !is null);

        return true;
    }
    else
    {
        return false;
    }
}

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

    this(InterfaceInfo if_, string mcastAddr = "ff02::1", ushort mcastPort = 1024) // should latter two be configurable?
    {
        // ensure that the interface is IPv6 and link-local
        // if(if_.getAddress().addressFamily() == AddressFamily.INET6 && if_.getAddress().name().sa_data)
        // might need sub-object cast


        this.if_ = if_;

        // Multicast socket for discovery
        this.mcastAddress = parseAddress(mcastAddr~"%"~if_.getName(), mcastPort);
        this.mcastSock = new Socket(AddressFamily.INET6, SocketType.DGRAM, ProtocolType.UDP);
        
        // Multicast thread
        this.mcastThread = new Thread(&mcastLoop);

        // Peering socket for transit
        writeln("before crash to bind: ", if_.getAddress().toAddrString());
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
        return if_.getAddress().toAddrString();
    }

    public override string toString()
    {
        return "LLInterface [name: "~if_.getName()~", address: "~if_.getAddress().toAddrString()~", recvs: "~to!(string)(getRecvCnt())~"]";
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
                Address fromAddr; // todo, do we need this?

                buffer.length = cnt;
                this.mcastSock.receiveFrom(buffer, fromAddr);
                writeln("from: ", fromAddr, "bytes: ", buffer);

                // Pass received data on upwards
                receive(buffer, fromAddr.toString()); // todo, pass in fromAddr
            }
        }
    }

    private void peerLoop()
    {
        while(this.running) // todo flag
        {
            byte[] buffer;

            // this.socket.receiveFrom(buffer, SocketFlags.PEEK|)
            Thread.sleep(dur!("seconds")(100)); 
        }
    }

    public void stop()
    {
        
    }

}