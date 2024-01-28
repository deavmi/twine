Encoding
========

The encoding and decoding for the twine protocol messages is accomplished via the **MessagePack**
format. This is a format of which allows one to encode data structures into a byte stream and
send them over the wire. It is a _format_ because it is standardized - meaning all languages
which have a message pack library can decode twine messages if they re-implement the simple
routines for the various messages - _all the hard work is accomplished by the underlying message pack
library used_.

## The `Message` type

TODO: Add this

### Message types

The type of a message is the first field which one will consider.
We store this as an enum value called `MType`, it is defined below:

```{.numberLines .d}
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
```

It is this type which will aid us in decoding the `byte[] payload`
field with the intended interpretation.