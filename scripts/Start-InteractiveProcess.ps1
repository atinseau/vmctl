#requires -Version 7.2
param([Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][string]$Arguments,[Parameter(Mandatory)][string]$WorkingDirectory)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class VmctlInteractiveLaunch {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct STARTUPINFO {
        public int cb; public string reserved, desktop, title;
        public int x,y,xSize,ySize,xCount,yCount,fill,flags;
        public short show, reservedSize; public IntPtr reservedPtr,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] struct PROCESSINFO { public IntPtr process,thread;public int pid,tid; }
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool DuplicateTokenEx(IntPtr token,uint access,IntPtr attributes,int level,int type,out IntPtr duplicate);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessWithTokenW(IntPtr token,uint logon,string application,string command,uint flags,IntPtr environment,string directory,ref STARTUPINFO startup,out PROCESSINFO info);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    public static int Start(int shellPid,string exe,string args,string directory) {
        IntPtr process=IntPtr.Zero,token=IntPtr.Zero,duplicate=IntPtr.Zero;
        PROCESSINFO info=new PROCESSINFO();
        try {
            process=OpenProcess(0x1000,false,shellPid);
            if(process==IntPtr.Zero || !OpenProcessToken(process,0x000A,out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if(!DuplicateTokenEx(token,0x02000000,IntPtr.Zero,2,1,out duplicate)) throw new Win32Exception(Marshal.GetLastWin32Error());
            STARTUPINFO startup=new STARTUPINFO();startup.cb=Marshal.SizeOf(startup);startup.desktop="winsta0\\default";startup.flags=1;startup.show=1;
            if(!CreateProcessWithTokenW(duplicate,1,exe,"\""+exe+"\" "+args,0,IntPtr.Zero,directory,ref startup,out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return info.pid;
        } finally {
            foreach(IntPtr handle in new[]{info.thread,info.process,duplicate,token,process}) if(handle!=IntPtr.Zero) CloseHandle(handle);
        }
    }
}
'@
$sessionId=(Get-Process -Id $PID).SessionId
$userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$shells=@(Get-Process explorer -ErrorAction SilentlyContinue|Where-Object {$_.SessionId -eq $sessionId}|Where-Object {
    $owner=Invoke-CimMethod (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)") -MethodName GetOwnerSid
    $owner.Sid -eq $userSid
}|Sort-Object Id)
if(-not $shells.Count){throw 'No matching interactive Windows shell was found.'}
[VmctlInteractiveLaunch]::Start($shells[0].Id,[IO.Path]::GetFullPath($Executable),$Arguments,[IO.Path]::GetFullPath($WorkingDirectory))
