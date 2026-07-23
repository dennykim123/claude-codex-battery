using System;
using System.IO;
using System.Net;

class TestFetch
{
    static void Main()
    {
        // Enforce TLS 1.2
        ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072; // Tls12

        string userDir = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string authPath = Path.Combine(userDir, ".codex", "auth.json");

        if (!File.Exists(authPath))
        {
            Console.WriteLine("auth.json not found!");
            return;
        }

        string content = File.ReadAllText(authPath);
        int idx = content.IndexOf("access_token");
        if (idx > 0)
        {
            int start = content.IndexOf("\"", idx + 14) + 1;
            int end = content.IndexOf("\"", start);
            string token = content.Substring(start, end - start);
            Console.WriteLine("Found Access Token (Length: " + token.Length + ")");

            HttpWebRequest req = (HttpWebRequest)WebRequest.Create("https://chatgpt.com/backend-api/wham/usage");
            req.Headers.Add("Authorization", "Bearer " + token);
            req.UserAgent = "claude-codex-battery-win/1.0";
            req.Timeout = 5000;

            try
            {
                using (WebResponse resp = req.GetResponse())
                using (StreamReader sr = new StreamReader(resp.GetResponseStream()))
                {
                    string body = sr.ReadToEnd();
                    Console.WriteLine("✅ LIVE API SUCCESS!");
                    Console.WriteLine(body);
                }
            }
            catch (WebException ex)
            {
                Console.WriteLine("Live API Exception: " + ex.Message);
                if (ex.Response != null)
                {
                    using (StreamReader sr = new StreamReader(ex.Response.GetResponseStream()))
                    {
                        Console.WriteLine("Response Body: " + sr.ReadToEnd());
                    }
                }
            }
        }
    }
}