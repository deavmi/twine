module twine.six.ll;

import core.thread;
import twine.links.link;
import std.socket : Socket, Address, parseAddress, AddressFamily, SocketType, ProtocolType;
import std.socket : SocketFlags, MSG_TRUNC, MSG_PEEK;
import std.stdio;



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

// todo, add saddr-to-6 method (assumes you checked the af_inet)
import std.socket : sockaddr;
public bool extract6addr_unsafe(sockaddr* a, AddressFamily af, ref ubyte[] address) @nogc
{
    if(a !is null)
    {
        if(a.sa_family == af)
        {
            // IPv6 address extraction
            if(af == AddressFamily.INET6)
            {
                // we can assuredly sub-struct cast because we know sa_family is INET6
                import twine.six.crap : sockaddr_in6, in6_addr;
                sockaddr_in6* saddr6 = cast(sockaddr_in6*)a;

                // note for some reason, we can't access it like that
                // doesn't matter as it is a struct with signle element
                // so we can just case to the element therein
                // of which is an `uint8_t[16]` (in D this is `ubyte[16]`)
                in6_addr addr = saddr6.sin6_addr;
                // addr.s6_addr; 
                ubyte[16] extractedAddr = cast(ubyte[16])addr;

                // place into destination
                address = extractedAddr;

                return true;
            }
            // Unsupported family
            else
            {
                return false;
            }
        }
        else
        {
            return false;
        }
    }
    else
    {
        return false;
    }
}

public bool getLinkLocalOf(string if_name, ref InterfaceInfo[] if_info)
{
    // todo, use predicate version of `getLinkLocal`
    // when it becomes avaibale
    InterfaceInfo[] available;

    if(getLinkLocal(available))
    {
        foreach(InterfaceInfo if_; available)
        {
            if(if_.getName() == if_name)
            {
                if_info ~= if_;
            }
        }

        return true;
    }
    else
    {
        return false;    
    }
}

// todo, below version should support a name-based predicate
public bool getLinkLocal(ref InterfaceInfo[] interfaces)
{
    InterfaceInfo[] initial;
    if(getIfAddrs(initial))
    {
        foreach(InterfaceInfo if_; initial)
        {
            AddressFamily if_af = if_.getAddress().addressFamily();
            if(if_af == AddressFamily.INET6)
            {
                ubyte[] addrTo;
                if(extract6addr_unsafe(cast(sockaddr*)if_.getAddress().name(), if_af, addrTo)) // todo, use const, remove cast
                {
                    // Copy into stack array that can be copied over too
                    ubyte[16] addr;
                    static foreach(i; 0..16)
                    {
                        addr[i] = addrTo[i];
                    }

                    if(isLinkLocal(addr))
                    {
                        // then append this one
                        interfaces ~= if_;
                    }
                }
            }
        }

        return true;
    }
    else
    {
        return false;
    }
}

public bool getIfAddrs(ref InterfaceInfo[] interfaces)
{
    import twine.six.crap : getifaddrs, ifaddrs; //, sockaddr, sockaddr_in6, in6_addr, uint8_t;

    ifaddrs* ifs;
    if(getifaddrs(&ifs) == 0)
    {
        scope(exit)
        {
            // free allocated list
            import twine.six.crap : freeifaddrs;
            freeifaddrs(ifs);
        }

        // ensure there is a first entry (just to be safe)
        ifaddrs* curIf = ifs;
        while(curIf !is null)
        {
            // extract interface name (we must copy, this doesn't allocate by itself)
            string name = cast(string)fromStringz(curIf.ifa_name).dup;

            // get the sockaddr (base struct)
            import twine.six.crap : sockaddr;
            sockaddr* saddr = curIf.ifa_addr;

            // if "UNSPEC" -> then null, it means the associuated family has no address (think of a tun adapter)
            if(saddr !is null)
            {
                // determine the type (so we can type cast to get sub-struct)
                import twine.six.crap : sa_family_t;
                import core.sys.posix.sys.socket : AF_INET, AF_INET6;
                sa_family_t family = saddr.sa_family;

                // AF_INET6
                if(family == AF_INET6)
                {
                    // cast to sockaddr_in6 sub-struct
                    import twine.six.crap : sockaddr_in6, in6_addr, in_port_t;
                    sockaddr_in6* saddrSix = cast(sockaddr_in6*)saddr;

                    // extract address and port
                    in6_addr in_addr = saddrSix.sin6_addr;
                    // I couldn't get to this so we will cast over it as the struct is single member
                    // and said member is fixed size of 16 bytes of ubyte (according to the docs)
                    // addr.s6_addr; 
                    // copy over (static array)
                    ubyte[16] addr = cast(ubyte[16])in_addr;


                    // simple enough - alias to `uint16_t`
                    in_port_t in_port = saddrSix.sin6_port;
                    ushort port = in_port;


                    // construct Internet6ADdress
                    import std.socket : Internet6Address;
                    interfaces ~= InterfaceInfo(name, new Internet6Address(addr, port));
                }
                // AF_INET
                else if(family == AF_INET)
                {

                }
                // todo, for now unsupported
                else
                {

                }
            }


            // move to next interface in linked-list
            curIf = curIf.ifa_next;
        }

        return true;
    }
    else
    {
        return false;
    }
}


version(unittest)
{
    import niknaks.debugging : dumpArray;
    import std.stdio : writeln;
}

unittest
{
    InterfaceInfo[] interfaces;
    assert(getIfAddrs(interfaces));
    writeln(dumpArray!(interfaces));
    
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
        return if_.getAddress().toAddrString();
    }

    public override string toString()
    {
        return "LLInterface [name: "~if_.getName()~", address: "~if_.getAddress().toAddrString()~", recvs: "~to!(string)(getRecvCnt())~"]";
    }

    public override void transmit(byte[] xmit, string addr)
    {
        // we could send via any socket probably, just destination address is iportant
        this.peerSock.sendTo(xmit, parseAddress(addr));
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