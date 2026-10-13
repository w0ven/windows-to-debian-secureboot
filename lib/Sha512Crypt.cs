using System;
using System.Security.Cryptography;
using System.Text;

namespace W2D
{
    /// <summary>
    /// Linux SHA-512 crypt with the standard 5000 rounds and UTF-8 passwords.
    /// No password normalization or truncation is performed. Invalid UTF-16 is rejected.
    /// Byte buffers are cleared on exit, but managed strings and crypto-provider
    /// internals cannot be guaranteed to have been erased. Never log passwords.
    /// Compatible with C# 5 and .NET Framework 4.7; no external dependencies.
    /// </summary>
    public static class Sha512Crypt
    {
        private const string Alphabet = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
        private const int Rounds = 5000;
        private static readonly byte[] Empty = new byte[0];

        public static string Hash(string password, string salt)
        {
            if (password == null)
                throw new ArgumentNullException("password");
            ValidateSalt(salt);

            byte[] passwordBytes = null;
            byte[] saltBytes = null;
            byte[] alternate = null;
            byte[] current = null;
            byte[] pDigest = null;
            byte[] pSequence = null;
            byte[] sDigest = null;
            byte[] sSequence = null;
            try
            {
                passwordBytes = new UTF8Encoding(false, true).GetBytes(password);
                saltBytes = Encoding.ASCII.GetBytes(salt);
                using (SHA512 sha = SHA512.Create())
                {
                    // Alternate digest B = SHA512(password + salt + password).
                    Add(sha, passwordBytes);
                    Add(sha, saltBytes);
                    Add(sha, passwordBytes);
                    alternate = Finish(sha);

                    // Initial digest A, including the password-length bit mixing.
                    Add(sha, passwordBytes);
                    Add(sha, saltBytes);
                    AddRepeated(sha, alternate, passwordBytes.Length);
                    for (int count = passwordBytes.Length; count > 0; count >>= 1)
                        Add(sha, (count & 1) != 0 ? alternate : passwordBytes);
                    current = Finish(sha);
                    Clear(alternate);
                    alternate = null;

                    // P: repeat the password password-byte-length times, hash it,
                    // then repeat that digest to the original password byte length.
                    for (int i = 0; i < passwordBytes.Length; i++)
                        Add(sha, passwordBytes);
                    pDigest = Finish(sha);
                    pSequence = Repeat(pDigest, passwordBytes.Length);
                    Clear(pDigest);
                    pDigest = null;

                    // S: the repetition count depends on the first byte of A.
                    for (int i = 0; i < 16 + current[0]; i++)
                        Add(sha, saltBytes);
                    sDigest = Finish(sha);
                    sSequence = Repeat(sDigest, saltBytes.Length);
                    Clear(sDigest);
                    sDigest = null;

                    for (int round = 0; round < Rounds; round++)
                    {
                        Add(sha, (round & 1) != 0 ? pSequence : current);
                        if (round % 3 != 0)
                            Add(sha, sSequence);
                        if (round % 7 != 0)
                            Add(sha, pSequence);
                        Add(sha, (round & 1) != 0 ? current : pSequence);
                        byte[] next = Finish(sha);
                        Clear(current);
                        current = next;
                    }
                }

                StringBuilder result = new StringBuilder(3 + salt.Length + 1 + 86);
                result.Append("$6$").Append(salt).Append('$');
                // SHA-512 crypt's byte permutation and little-endian crypt base64.
                Encode(result, current[0], current[21], current[42], 4);
                Encode(result, current[22], current[43], current[1], 4);
                Encode(result, current[44], current[2], current[23], 4);
                Encode(result, current[3], current[24], current[45], 4);
                Encode(result, current[25], current[46], current[4], 4);
                Encode(result, current[47], current[5], current[26], 4);
                Encode(result, current[6], current[27], current[48], 4);
                Encode(result, current[28], current[49], current[7], 4);
                Encode(result, current[50], current[8], current[29], 4);
                Encode(result, current[9], current[30], current[51], 4);
                Encode(result, current[31], current[52], current[10], 4);
                Encode(result, current[53], current[11], current[32], 4);
                Encode(result, current[12], current[33], current[54], 4);
                Encode(result, current[34], current[55], current[13], 4);
                Encode(result, current[56], current[14], current[35], 4);
                Encode(result, current[15], current[36], current[57], 4);
                Encode(result, current[37], current[58], current[16], 4);
                Encode(result, current[59], current[17], current[38], 4);
                Encode(result, current[18], current[39], current[60], 4);
                Encode(result, current[40], current[61], current[19], 4);
                Encode(result, current[62], current[20], current[41], 4);
                Encode(result, 0, 0, current[63], 2);
                return result.ToString();
            }
            finally
            {
                Clear(passwordBytes);
                Clear(saltBytes);
                Clear(alternate);
                Clear(current);
                Clear(pDigest);
                Clear(pSequence);
                Clear(sDigest);
                Clear(sSequence);
            }
        }

        /// <summary>Generate 16 unbiased crypt-alphabet characters using the OS CSPRNG.</summary>
        public static string GenerateSalt()
        {
            byte[] random = new byte[16];
            char[] characters = new char[16];
            try
            {
                using (RandomNumberGenerator rng = RandomNumberGenerator.Create())
                    rng.GetBytes(random);
                // 64 divides 256, so masking six bits does not introduce bias.
                for (int i = 0; i < characters.Length; i++)
                    characters[i] = Alphabet[random[i] & 63];
                return new string(characters);
            }
            finally
            {
                Clear(random);
                Array.Clear(characters, 0, characters.Length);
            }
        }

        private static void ValidateSalt(string salt)
        {
            if (salt == null)
                throw new ArgumentNullException("salt");
            if (salt.Length < 1 || salt.Length > 16)
                throw new ArgumentException("Salt must contain 1-16 crypt-alphabet characters.", "salt");
            for (int i = 0; i < salt.Length; i++)
                if (Alphabet.IndexOf(salt[i]) < 0)
                    throw new ArgumentException("Salt contains a character outside [./0-9A-Za-z].", "salt");
        }

        private static void Add(HashAlgorithm sha, byte[] bytes)
        {
            if (bytes.Length > 0)
                sha.TransformBlock(bytes, 0, bytes.Length, bytes, 0);
        }

        private static void AddRepeated(HashAlgorithm sha, byte[] digest, int length)
        {
            while (length > 0)
            {
                int count = Math.Min(digest.Length, length);
                sha.TransformBlock(digest, 0, count, digest, 0);
                length -= count;
            }
        }

        private static byte[] Finish(HashAlgorithm sha)
        {
            sha.TransformFinalBlock(Empty, 0, 0);
            byte[] digest = sha.Hash;
            sha.Initialize();
            return digest;
        }

        private static byte[] Repeat(byte[] digest, int length)
        {
            byte[] sequence = new byte[length];
            for (int offset = 0; offset < length; )
            {
                int count = Math.Min(digest.Length, length - offset);
                Buffer.BlockCopy(digest, 0, sequence, offset, count);
                offset += count;
            }
            return sequence;
        }

        private static void Encode(StringBuilder result, byte high, byte middle, byte low, int count)
        {
            uint value = ((uint)high << 16) | ((uint)middle << 8) | low;
            for (int i = 0; i < count; i++)
            {
                result.Append(Alphabet[(int)(value & 63)]);
                value >>= 6;
            }
        }

        private static void Clear(byte[] bytes)
        {
            if (bytes != null)
                Array.Clear(bytes, 0, bytes.Length);
        }
    }
}
