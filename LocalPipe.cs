// 仅允许通过本机命名管道发送 GET /connections；无远程网络或写入代理配置功能。
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
public static class CodexLocalPipe {
    public static string Connections(string pipeName, string secret) {
        if (pipeName.IndexOfAny(new char[]{'\\','/','\r','\n'}) >= 0) throw new ArgumentException("Invalid local pipe name");
        if (secret.Contains("\r") || secret.Contains("\n")) throw new ArgumentException("Invalid authorization value");
        using (var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous)) {
            pipe.Connect(2000);
            var request = Encoding.UTF8.GetBytes("GET /connections HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer " + secret + "\r\nConnection: close\r\n\r\n");
            pipe.Write(request,0,request.Length); pipe.Flush();
            using (var data = new MemoryStream()) {
                var buffer = new byte[32768];
                while (true) {
                    var read = pipe.ReadAsync(buffer,0,buffer.Length);
                    if (!read.Wait(3000)) throw new IOException("Local proxy read timeout");
                    if (read.Result==0) break;
                    data.Write(buffer,0,read.Result);
                    if (data.Length>16*1024*1024) throw new IOException("Local response too large");
                }
                byte[] bytes=data.ToArray(); int split=-1;
                for(int i=0;i+3<bytes.Length;i++) if(bytes[i]==13 && bytes[i+1]==10 && bytes[i+2]==13 && bytes[i+3]==10){split=i;break;}
                if(split<0) throw new IOException("Invalid local HTTP response");
                string header=Encoding.ASCII.GetString(bytes,0,split);
                if(!header.StartsWith("HTTP/1.1 200") && !header.StartsWith("HTTP/1.0 200")) throw new IOException("Local proxy authorization or API failure");
                int pos=split+4;
                if(header.ToLowerInvariant().Contains("transfer-encoding: chunked")) {
                    using(var body=new MemoryStream()) {
                        while(true) {
                            int end=pos; while(end+1<bytes.Length && !(bytes[end]==13 && bytes[end+1]==10)) end++;
                            if(end+1>=bytes.Length) throw new IOException("Invalid chunk header");
                            int size=Convert.ToInt32(Encoding.ASCII.GetString(bytes,pos,end-pos).Split(';')[0],16);
                            pos=end+2; if(size==0) break;
                            if(size<0 || pos+size+2>bytes.Length) throw new IOException("Truncated chunk");
                            body.Write(bytes,pos,size); pos+=size+2;
                        }
                        return Encoding.UTF8.GetString(body.ToArray());
                    }
                }
                return Encoding.UTF8.GetString(bytes,pos,bytes.Length-pos);
            }
        }
    }
}
