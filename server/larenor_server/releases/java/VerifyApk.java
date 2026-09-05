package org.larenor.updates;

import com.android.apksig.ApkVerifier;
import com.android.apksig.apk.ApkUtils;
import com.android.apksig.internal.apk.AndroidBinXmlParser;
import java.io.File;
import java.nio.ByteBuffer;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.zip.ZipFile;

/** Only parses and verifies the APK; never loads its classes or executes code. */
public final class VerifyApk {
    public static void main(String[] args) {
        if (args.length != 1) System.exit(4);
        try {
            File file = new File(args[0]);
            if (!file.isFile() || file.length() < 1 || file.length() > 512L * 1024 * 1024) throw new Exception();
            byte[] xml;
            try (ZipFile zip = new ZipFile(file)) {
                int count = 0, manifests = 0;
                var entries = zip.entries();
                while (entries.hasMoreElements()) {
                    var entry = entries.nextElement();
                    if (++count > 100000) throw new Exception();
                    if (entry.getName().equals("AndroidManifest.xml")) manifests++;
                }
                var manifest = zip.getEntry("AndroidManifest.xml");
                if (manifests != 1 || manifest == null || manifest.getSize() < 0 || manifest.getSize() > 262144) throw new Exception();
                try (var input = zip.getInputStream(manifest)) { xml = input.readNBytes(262145); }
                if (xml.length > 262144) throw new Exception();
            }
            var result = new ApkVerifier.Builder(file).setMinCheckedPlatformVersion(26).setMaxCheckedPlatformVersion(37).build().verify();
            if (!result.isVerified() || result.getSignerCertificates().size() != 1) throw new Exception();
            String certificate = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(result.getSignerCertificates().get(0).getEncoded()));
            String application = ApkUtils.getPackageNameFromBinaryAndroidManifest(ByteBuffer.wrap(xml));
            long version = ApkUtils.getLongVersionCodeFromBinaryAndroidManifest(ByteBuffer.wrap(xml));
            int minSdk = ApkUtils.getMinSdkVersionFromBinaryAndroidManifest(ByteBuffer.wrap(xml));
            boolean debuggable = ApkUtils.getDebuggableFromBinaryAndroidManifest(ByteBuffer.wrap(xml));
            String versionName = null;
            var parser = new AndroidBinXmlParser(ByteBuffer.wrap(xml));
            while (parser.getEventType() != AndroidBinXmlParser.EVENT_END_DOCUMENT) {
                if (parser.getEventType() == AndroidBinXmlParser.EVENT_START_ELEMENT && parser.getDepth() == 1 &&
                    parser.getName().equals("manifest") && parser.getNamespace().isEmpty()) {
                    for (int i = 0; i < parser.getAttributeCount(); i++) {
                        if (parser.getAttributeNameResourceId(i) == 0x0101021c) {
                            if (versionName != null || parser.getAttributeValueType(i) != AndroidBinXmlParser.VALUE_TYPE_STRING) throw new Exception();
                            versionName = parser.getAttributeStringValue(i);
                        }
                        // Split APKs are not a complete, installable release.
                        if (parser.getAttributeName(i).equals("split") && parser.getAttributeNamespace(i).isEmpty()) throw new Exception();
                    }
                }
                parser.next();
            }
            if (application == null || application.length() > 100 || version < 1 || version > 2147483647 ||
                versionName == null || versionName.isBlank() || versionName.length() > 80 || minSdk < 1 || minSdk > 100) throw new Exception();
            System.out.println("{\"schemaVersion\":1,\"verified\":true,\"applicationId\":" + quote(application) +
                ",\"versionCode\":" + version + ",\"versionName\":" + quote(versionName) +
                ",\"minSdk\":" + minSdk + ",\"certificateSha256\":" + quote(certificate) + ",\"debuggable\":" + debuggable + "}");
        } catch (Throwable failure) {
            // An APK parser exception may include archive names/content.
            System.exit(3);
        }
    }
    private static String quote(String value) {
        StringBuilder out = new StringBuilder("\"");
        for (char c : value.toCharArray()) {
            if (c == '"' || c == '\\') out.append('\\').append(c);
            else if (c < 32 || c == 127) out.append(String.format("\\u%04x", (int)c));
            else out.append(c);
        }
        return out.append('"').toString();
    }
}
