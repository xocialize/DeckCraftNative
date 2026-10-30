// Apache POI (Apache-2.0) as an independent producer and reader of legacy test files, run as a single-file Java
// program (`java -cp '<poi jars>/*' Tools/legacy/PoiTool.java …`). Never ported: DeckCraftNative implements the
// formats from Microsoft's Open Specifications; POI only makes encrypted test files and reads files for comparison.
// It never starts a .ppt from POI's own blank template (that file was saved by PowerPoint): `.ppt` input always comes
// from LibreOffice.
//
//   encrypt-ooxml agile|standard aes128|aes192|aes256 sha1|sha256|sha384|sha512 PASSWORD IN.pptx OUT.pptx
//       wrap IN's exact bytes as an encrypted OOXML package ([MS-OFFCRYPTO] Agile or Standard)
//   decrypt-ooxml PASSWORD IN OUT.pptx    write the decrypted package; exit 2 on a wrong password
//   encrypt-ppt PASSWORD IN.ppt OUT.ppt   re-save a .ppt encrypted with RC4 CryptoAPI
//   dump-ppt IN.ppt [PASSWORD]            slides, shapes and text as JSON on stdout
//   list-cfb IN                           a compound file's storages and streams (path, kind, size, sha256) as JSON,
//                                         the shape of fixtures.py olefile-list
import java.awt.geom.Rectangle2D;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import org.apache.poi.hslf.usermodel.*;
import org.apache.poi.hssf.record.crypto.Biff8EncryptionKey;
import org.apache.poi.poifs.crypt.*;
import org.apache.poi.poifs.filesystem.DirectoryEntry;
import org.apache.poi.poifs.filesystem.DocumentEntry;
import org.apache.poi.poifs.filesystem.DocumentInputStream;
import org.apache.poi.poifs.filesystem.Entry;
import org.apache.poi.poifs.filesystem.POIFSFileSystem;

public class PoiTool {
    public static void main(String[] a) throws Exception {
        if (a.length == 0) usage();
        switch (a[0]) {
            case "encrypt-ooxml" -> {
                if (a.length != 7) usage();
                EncryptionMode mode = a[1].equals("standard") ? EncryptionMode.standard : EncryptionMode.agile;
                CipherAlgorithm cipher = CipherAlgorithm.valueOf(a[2]);
                HashAlgorithm hash = HashAlgorithm.valueOf(a[3]);
                EncryptionInfo info = mode == EncryptionMode.standard
                    ? new EncryptionInfo(mode, cipher, hash, -1, -1, null)
                    : new EncryptionInfo(mode, cipher, hash, -1, -1, ChainingMode.cbc);
                Encryptor enc = info.getEncryptor();
                enc.confirmPassword(a[4]);
                try (POIFSFileSystem fs = new POIFSFileSystem()) {
                    try (OutputStream os = enc.getDataStream(fs)) { Files.copy(Path.of(a[5]), os); }
                    try (FileOutputStream out = new FileOutputStream(a[6])) { fs.writeFilesystem(out); }
                }
            }
            case "decrypt-ooxml" -> {
                if (a.length != 4) usage();
                try (POIFSFileSystem fs = new POIFSFileSystem(new File(a[2]), true)) {
                    EncryptionInfo info = new EncryptionInfo(fs);
                    Decryptor d = Decryptor.getInstance(info);
                    if (!d.verifyPassword(a[1])) { System.err.println("wrong password"); System.exit(2); }
                    try (InputStream is = d.getDataStream(fs)) { Files.copy(is, Path.of(a[3]), StandardCopyOption.REPLACE_EXISTING); }
                }
            }
            case "encrypt-ppt" -> {
                if (a.length != 4) usage();
                Biff8EncryptionKey.setCurrentUserPassword(a[1]);
                try (HSLFSlideShow ss = new HSLFSlideShow(new FileInputStream(a[2]));
                     FileOutputStream out = new FileOutputStream(a[3])) {
                    ss.write(out);
                } finally {
                    Biff8EncryptionKey.setCurrentUserPassword(null);
                }
            }
            case "dump-ppt" -> {
                if (a.length < 2 || a.length > 3) usage();
                if (a.length == 3) Biff8EncryptionKey.setCurrentUserPassword(a[2]);
                try (HSLFSlideShow ss = new HSLFSlideShow(new FileInputStream(a[1]))) {
                    System.out.println(dump(ss));
                } finally {
                    Biff8EncryptionKey.setCurrentUserPassword(null);
                }
            }
            case "list-cfb" -> {
                if (a.length != 2) usage();
                try (POIFSFileSystem fs = new POIFSFileSystem(new File(a[1]), true)) {
                    List<String> rows = new ArrayList<>();
                    list(fs.getRoot(), "", rows);
                    rows.sort(Comparator.comparing(r -> r.substring(9, r.indexOf('"', 9)).toLowerCase(Locale.ROOT)));
                    System.out.println("{\"entries\":[" + String.join(",", rows) + "]}");
                }
            }
            default -> usage();
        }
    }

    static void list(DirectoryEntry dir, String prefix, List<String> rows) throws Exception {
        for (Iterator<Entry> it = dir.getEntries(); it.hasNext(); ) {
            Entry e = it.next();
            String path = prefix.isEmpty() ? e.getName() : prefix + "/" + e.getName();
            if (e instanceof DirectoryEntry d) {
                rows.add("{\"path\":" + str(path) + ",\"kind\":\"storage\"}");
                list(d, path, rows);
            } else if (e instanceof DocumentEntry doc) {
                byte[] data;
                try (DocumentInputStream in = new DocumentInputStream(doc)) { data = in.readAllBytes(); }
                StringBuilder h = new StringBuilder();
                for (byte x : java.security.MessageDigest.getInstance("SHA-256").digest(data)) h.append(String.format("%02x", x));
                rows.add("{\"path\":" + str(path) + ",\"kind\":\"stream\",\"size\":" + data.length + ",\"sha256\":\"" + h + "\"}");
            }
        }
    }

    static String dump(HSLFSlideShow ss) {
        StringBuilder b = new StringBuilder();
        java.awt.Dimension size = ss.getPageSize();
        b.append("{\"width\":").append(size.width).append(",\"height\":").append(size.height).append(",\"slides\":[");
        List<HSLFSlide> slides = ss.getSlides();
        for (int i = 0; i < slides.size(); i++) {
            HSLFSlide s = slides.get(i);
            if (i > 0) b.append(',');
            b.append("{\"index\":").append(i + 1).append(",\"hidden\":").append(s.isHidden()).append(",\"shapes\":");
            shapes(b, s.getShapes());
            HSLFNotes n = s.getNotes();
            StringBuilder notes = new StringBuilder();
            if (n != null) for (List<HSLFTextParagraph> paras : n.getTextParagraphs()) notes.append(HSLFTextParagraph.getText(paras)).append('\n');
            b.append(",\"notes\":").append(str(notes.toString().strip())).append('}');
        }
        return b.append("]}").toString();
    }

    static void shapes(StringBuilder b, List<HSLFShape> list) {
        b.append('[');
        for (int i = 0; i < list.size(); i++) {
            HSLFShape sh = list.get(i);
            if (i > 0) b.append(',');
            Rectangle2D r = sh.getAnchor();
            b.append("{\"kind\":").append(str(sh.getClass().getSimpleName()))
             .append(",\"type\":").append(str(sh.getShapeType() == null ? "" : sh.getShapeType().name()))
             .append(",\"name\":").append(str(sh.getShapeName()))
             .append(String.format(Locale.ROOT, ",\"x\":%.2f,\"y\":%.2f,\"w\":%.2f,\"h\":%.2f", r.getX(), r.getY(), r.getWidth(), r.getHeight()));
            if (sh instanceof HSLFTextShape t) b.append(",\"text\":").append(str(t.getText()));
            if (sh instanceof HSLFTable tb) b.append(",\"rows\":").append(tb.getNumberOfRows()).append(",\"cols\":").append(tb.getNumberOfColumns());
            if (sh instanceof HSLFGroupShape g) { b.append(",\"children\":"); shapes(b, g.getShapes()); }
            b.append('}');
        }
        b.append(']');
    }

    static String str(String s) {
        if (s == null) return "null";
        StringBuilder b = new StringBuilder("\"");
        for (char c : s.toCharArray()) {
            switch (c) {
                case '"' -> b.append("\\\"");
                case '\\' -> b.append("\\\\");
                case '\n' -> b.append("\\n");
                case '\r' -> b.append("\\r");
                case '\t' -> b.append("\\t");
                default -> { if (c < 0x20) b.append(String.format("\\u%04x", (int) c)); else b.append(c); }
            }
        }
        return b.append('"').toString();
    }

    static void usage() {
        System.err.println("usage: PoiTool encrypt-ooxml|decrypt-ooxml|encrypt-ppt|dump-ppt|list-cfb … (see the file's header)");
        System.exit(64);
    }
}
