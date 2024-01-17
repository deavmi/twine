module twine.core.keys;

import crypto.rsa;

public struct Identity
{
    private string publicKey;
    private string privateKey;

    @disable
    this();

    this(string publicKey, string privateKey)
    {
        this.publicKey = publicKey;
        this.privateKey = privateKey;
    }

    public string getPublicKey()
    {
        return this.publicKey;
    }

    public string getPrivateKey()
    {
        return this.privateKey;
    }

    public ubyte[] identity_b()
    {
        import std.digest.sha : sha512Of;
        return sha512Of(getPublicKey()).dup;
    }

    public string identity()
    {
        // hex of hash of public key
        import std.digest : toHexString;
        return toHexString(identity_b());
    }

    public static Identity newIdentity()
    {
        RSAKeyPair kp = RSA.generateKeyPair();
        return Identity(kp.publicKey, kp.privateKey);
    }
}