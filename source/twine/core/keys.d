module twine.core.keys;

import crypto.rsa : RSA, RSAKeyPair;

public const struct Identity
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

private alias rsa_encrypt = RSA.encrypt;

public byte[] encrypt(byte[] raw, string publicKey)
{
    return cast(byte[])rsa_encrypt(publicKey, cast(ubyte[])raw);
}

private alias rsa_decrypt = RSA.decrypt;

public byte[] decrypt(byte[] encrypted, string privateKey)
{
    return cast(byte[])rsa_decrypt(privateKey, cast(ubyte[])encrypted);
}