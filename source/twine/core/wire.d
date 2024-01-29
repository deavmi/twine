module twine.core.wire;

// todo, in future a custom packer, unpacker interface could
// be declared, this would only be good for prototyping
// different serializer formats, not great for compat because it
// breaks the protocol

import msgpack;

/** 
 * Message type
 */
public enum MType
{
    /**
     * An unknown type
     *
     * Used for developer
     * safety as this would
     * be the value for
     * `MType.init` and hence
     * implies you haven't
     * set the `Message`'s
     * type field
     */
    UNKNOWN,

    /**
     * A route advertisement
     * message
     */
    ADV,
    
    /** 
     * Unicast data
     * packet
     */
    DATA,

    /** 
     * An ARP request
     * or reply
     */
    ARP
}

public struct Message
{
    /** 
     * The type of message (how to
     * interpret the payload)
     */
    private MType mType;

    /** 
     * The payload itself
     */
    private byte[] payload;

    /** 
     * Encodes the given `Message`
     * into a byte stream
     *
     * Params:
     *   mIn = the message to
     * encode
     * Returns: encoded bytes
     */
    public static byte[] encode(Message mIn)
    {
        return cast(byte[])pack(mIn);
    }

    /** 
     * Encodes this `Message`
     *
     * Returns: encoded bytes
     */
    public byte[] encode()
    {
        return encode(this);
    }

    /** 
     * Decoes the given data into the provided
     * `Message` variable
     *
     * Params:
     *   dataIn = the data to decode
     *   decoded = the decoded `Message`
     * Returns: `true` if the decode succeeded,
     * otherwise `false`
     */
    public static bool decode(byte[] dataIn, ref Message decoded)
    {
        try
        {
            decoded = unpack!(Message)(cast(ubyte[])dataIn);
            return true;
        }
        catch(MessagePackException u)
        {
            return false;
        }
    }

    public MType getType()
    {
        return this.mType;
    }

    public bool decodeAs(T)(ref T payloadOut)
    {
        // requested type `T` to the type within ourselves
        if(typeToMType!(T)() != this.getType())
        {
            return false;
        }

        return decodeAs!(T)(this.payload, payloadOut);
    }

    public static bool decodeAs(T)(byte[] payloadBytes, ref T payloadOut)
    {
        static if
        (
            __traits(isSame, T, Advertisement) ||
            __traits(isSame, T, Data) ||
            __traits(isSame, T, Arp)
        )
        {
            payloadOut = unpack!(T)(cast(ubyte[])payloadBytes);
            return true;
        }
        else
        {
            return false;
        }
    }

    // todo, make nice
    // public string toString()
    // {
        
    // }
}

public struct Data
{
    private ubyte ttl = 255;
    private byte[] data;
    private string src, dst;

    this(byte[] data, string src, string dst)
    {
        this.data = data;
        this.src = src;
        this.dst = dst;
    }

    public static bool makeDataPacket(string source, string destination, byte[] payload, ref Data dataOut)
    {
        // needs a valid srcAddr and dstAddr
        if(source.length && destination.length)
        {
            Data dataPkt = Data(payload, source, destination);
            dataOut = dataPkt;
            return true;
        }
        // needs both of these
        else
        {
            return false;    
        }
    }

    public ubyte getTTL()
    {
        return this.ttl;
    }

    public bool hasExpired()
    {
        return getTTL() == 0;
    }

    public void skim()
    {
        this.ttl--;
    }

    public byte[] getPayload()
    {
        return this.data;
    }

    public string getSrc()
    {
        return this.src;
    }

    public string getDst() const
    {
        return this.dst;
    }
}

public struct ArpReply
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

private bool nothrow_unpack(T)(ref T unpackStructure, byte[] fromData)
{
    try
    {
        unpackStructure = unpack!(T)(cast(ubyte[])fromData);
        return true;
    }
    catch(UnpackException e)
    {
        return false;
    }
}

public struct Arp
{
    private enum ArpType
    {
        REQUEST,
        RESPONSE
    }

    private ArpType aType;
    private byte[] content;

    public static Arp newRequest(string wants)
    {
        Arp arp;
        arp.aType = ArpType.REQUEST;
        arp.content = cast(byte[])pack(wants);
        return arp;
    }

    public bool getRequestedL3(ref string l3Addr)
    {
        // sanity check, can decode if a request
        if(getType() == ArpType.REQUEST)
        {
            return nothrow_unpack(l3Addr, this.content);
        }
        else
        {
            return false;
        }
    }

    public bool makeResponse(string llAddr, ref Arp respOut)
    {
        // sanity check, can only make response if currently request
        if(getType() == ArpType.REQUEST)
        {
            // get the requested network addr
            string networkAddr;

            // ensure we can unpack
            if(nothrow_unpack(networkAddr, this.content))
            {
                // l3Addr -> llAddr mapping
                ArpReply map = ArpReply(networkAddr, llAddr);

                // create response
                Arp resp;
                resp.aType = ArpType.RESPONSE;
                resp.content = cast(byte[])pack(map);

                respOut = resp;
                return true;
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

    public ArpType getType()
    {
        return this.aType;
    }

    public bool isRequest()
    {
        return getType() == ArpType.REQUEST;
    }

    public bool getReply(ref ArpReply reply)
    {
        // incase not right type
        if(getType() == ArpType.RESPONSE)
        {
            return nothrow_unpack(reply, this.content);
        }
        else
        {
            return false;    
        }
    }
}

public struct RouteAdvertisement
{
    private string addr;
    private ubyte distance;

    this(string address, ubyte distance)
    {
        this.addr = address;
        this.distance = distance;
    }

    public string getAddr()
    {
        return this.addr;
    }

    public ubyte getDistance()
    {
        return this.distance;
    }
}

public struct Advertisement
{
    private string origin;

    private enum AdvType
    {
        ADVERTISEMENT,
        RETRACTION

        // todo, could add a eager hello, and also goodbye
    }

    private AdvType aType;

    private byte[] content;


    private string dummy;
    this(string dummy)
    {
        this.dummy = dummy;
    }

    public string getDummy()
    {
        return this.dummy;
    }

    public string getOrigin()
    {
        return this.origin;
    }

    public bool isAdvertisement()
    {
        return this.aType == AdvType.ADVERTISEMENT;
    }

    public static Advertisement newAdvertisement(string dst, string origin, ubyte distance)
    {
        Advertisement advReq;
        advReq.aType = AdvType.ADVERTISEMENT;
        advReq.content = cast(byte[])pack(RouteAdvertisement(dst, distance));
        advReq.origin = origin;

        return advReq;
    }

    public bool getAdvertisement(ref RouteAdvertisement raOut)
    {
        return nothrow_unpack(raOut, this.content);
    }
}

private MType typeToMType(alias T)()
{
    static if(__traits(isSame, T, Advertisement))
    {
        return MType.ADV;
    }
    else static if(__traits(isSame, T, Data))
    {
        return MType.DATA;
    }
    else static if(__traits(isSame, T, Arp))
    {
        return MType.ARP;
    }
    else
    {
        return MType.UNKNOWN;
    }
}

// given a payload, this sets the right mType and trues encoding
// it for you
public bool toMessage(T)(T payloadIn, ref Message messageOut)
{
    // determine the type of payload
    MType payloadType = typeToMType!(T);

    Message message;
    message.mType = payloadType;
    message.payload = cast(byte[])pack(payloadIn);

    switch(payloadType)
    {
        case MType.UNKNOWN:
            return false;
        default:
            // todo, pack here rather
            messageOut = message;
            return true;
    }
}