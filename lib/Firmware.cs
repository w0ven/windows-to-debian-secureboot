using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace W2D {
    public static class Firmware {
        public const string Global = "{8be4df61-93ca-11d2-aa0d-00e098032b8c}";
        public const string Security = "{d719b2cb-3d3a-4596-a3bc-dad00e67656f}";
        [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential)] struct TokenPrivileges { public uint Count; public Luid Luid; public uint Attributes; }
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool LookupPrivilegeValue(string system, string name, out Luid luid);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disable, ref TokenPrivileges state, uint size, IntPtr previous, IntPtr needed);
        [DllImport("kernel32.dll", EntryPoint="GetFirmwareEnvironmentVariableExW", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetVariable(string name, string guid, byte[] data, uint size, out uint attributes);
        [DllImport("kernel32.dll", EntryPoint="SetFirmwareEnvironmentVariableExW", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetVariable(string name, string guid, byte[] data, uint size, uint attributes);

        public static void EnablePrivilege() {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) throw new Win32Exception();
            try {
                Luid luid;
                if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid)) throw new Win32Exception();
                TokenPrivileges state = new TokenPrivileges { Count=1, Luid=luid, Attributes=2 };
                if (!AdjustTokenPrivileges(token, false, ref state, 0, IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception();
                int error = Marshal.GetLastWin32Error();
                if (error != 0) throw new Win32Exception(error);
            } finally { CloseHandle(token); }
        }
        public static byte[] Read(string name, string guid) {
            byte[] data = new byte[1024 * 1024]; uint attributes;
            uint size = GetVariable(name, guid, data, (uint)data.Length, out attributes);
            if (size == 0) {
                int error = Marshal.GetLastWin32Error();
                if (error == 203) return null;
                throw new Win32Exception(error);
            }
            Array.Resize(ref data, (int)size); return data;
        }
        public static byte[] ReadGlobal(string name) { return Read(name, Global); }
        public static void WriteGlobal(string name, byte[] data) {
            if (!SetVariable(name, Global, data, (uint)data.Length, 7)) throw new Win32Exception();
        }
        public static void DeleteGlobal(string name) {
            if (!SetVariable(name, Global, new byte[0], 0, 0)) throw new Win32Exception();
        }
        public static void AppendAuthenticatedDb(byte[] payload) {
            // NV | BS | RT | TIME_BASED_AUTHENTICATED_WRITE_ACCESS | APPEND_WRITE.
            if (!SetVariable("db", Security, payload, (uint)payload.Length, 0x67)) throw new Win32Exception();
        }
        public static string Sha256(byte[] data) {
            using (SHA256 hash = SHA256.Create()) { return BitConverter.ToString(hash.ComputeHash(data)).Replace("-", "").ToLowerInvariant(); }
        }
        public static string[] SignatureEntries(byte[] data, bool certificatesOnly) {
            List<string> entries = new List<string>(); int offset=0;
            Guid x509 = new Guid("a159c0a5-e494-4aa7-87b5-ab155c2bf072");
            while (offset < data.Length) {
                if (data.Length-offset < 28) throw new InvalidDataException("Truncated EFI signature list");
                byte[] id=new byte[16]; Buffer.BlockCopy(data, offset, id, 0, 16);
                uint length=BitConverter.ToUInt32(data, offset+16), header=BitConverter.ToUInt32(data, offset+20), signature=BitConverter.ToUInt32(data, offset+24);
                if (length<28 || length>(uint)(data.Length-offset) || header>length-28 || signature<=16 || (length-28-header)%signature!=0) throw new InvalidDataException("Invalid EFI signature list");
                int start=offset+28+(int)header, end=offset+(int)length;
                for (int p=start; p<end; p+=(int)signature) {
                    if (certificatesOnly && new Guid(id)!=x509) continue;
                    int skip=certificatesOnly ? 16 : 0;
                    byte[] value=new byte[signature-(uint)skip]; Buffer.BlockCopy(data,p+skip,value,0,value.Length);
                    entries.Add((certificatesOnly ? "" : new Guid(id).ToString()+":")+Sha256(value));
                }
                offset=end;
            }
            return entries.ToArray();
        }
        public static byte[] BootOption(Guid partitionGuid, uint partitionNumber, ulong startLba, ulong sizeLba, string path) {
            if (partitionGuid==Guid.Empty || partitionNumber==0 || sizeLba==0 || path!="\\EFI\\w2d\\shimx64.efi") throw new ArgumentException("Invalid test boot device path");
            using (MemoryStream device=new MemoryStream()) {
                BinaryWriter w=new BinaryWriter(device);
                w.Write((byte)4); w.Write((byte)1); w.Write((ushort)42);
                w.Write(partitionNumber); w.Write(startLba); w.Write(sizeLba); w.Write(partitionGuid.ToByteArray()); w.Write((byte)2); w.Write((byte)2);
                byte[] file=Encoding.Unicode.GetBytes(path+"\0");
                w.Write((byte)4); w.Write((byte)4); w.Write((ushort)(file.Length+4)); w.Write(file);
                w.Write((byte)0x7f); w.Write((byte)0xff); w.Write((ushort)4); w.Flush();
                using (MemoryStream option=new MemoryStream()) {
                    BinaryWriter v=new BinaryWriter(option);
                    v.Write((uint)1); v.Write((ushort)device.Length); v.Write(Encoding.Unicode.GetBytes("W2D Debian 13 trial\0")); v.Write(device.ToArray()); v.Flush();
                    return option.ToArray();
                }
            }
        }
    }
}
