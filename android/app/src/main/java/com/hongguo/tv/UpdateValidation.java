package com.hongguo.tv;

import java.util.Set;

public final class UpdateValidation {
    public static final String PACKAGE = "com.hongguo.tv";
    public static final String CERTIFICATE = "55c3c3395a00e56e99b8bfd580b14c99618da74db19692a2e42606eb05c47ba9";
    public static final long MAXIMUM_BYTES = 256L * 1024 * 1024;

    public static void verifyBytes(long expected, long actual, String expectedHash, String actualHash) {
        require(expected > 0 && expected <= MAXIMUM_BYTES && expected == actual, "安装包大小不一致");
        require(expectedHash != null && expectedHash.matches("[a-f0-9]{64}") && expectedHash.equals(actualHash), "安装包 SHA-256 校验失败");
    }

    public static void verifyVersionName(String expected, String actual) {
        require(expected != null && expected.matches("[0-9]+[.][0-9]+[.][0-9]+")
                && expected.equals(actual), "安装包版本名称与更新信息不一致");
    }

    public static void verifyIdentity(String installedPackage, String archivePackage,
            Set<String> installedSigners, Set<String> archiveSigners,
            long installedCode, long archiveCode, long expectedCode,
            String installedAbi, Set<String> archiveAbis, String requestedAbi) {
        require(PACKAGE.equals(installedPackage) && PACKAGE.equals(archivePackage), "安装包包名不匹配");
        require(installedSigners.size() == 1 && installedSigners.contains(CERTIFICATE)
                && installedSigners.equals(archiveSigners), "安装包签名与当前正式版不匹配");
        require(archiveCode > installedCode && archiveCode == expectedCode, "安装包版本不是预期的新版本");
        int offset = offset(installedAbi);
        require(offset > 0 && installedCode > offset && installedCode < offset + 1000
                && archiveCode > offset && archiveCode < offset + 1000, "安装包版本编号与架构不匹配");
        require(installedAbi.equals(requestedAbi) && archiveAbis.size() == 1 && archiveAbis.contains(installedAbi), "安装包架构与已安装应用不匹配");
    }

    public static int offset(String abi) {
        if ("armeabi-v7a".equals(abi)) return 1000;
        if ("arm64-v8a".equals(abi)) return 2000;
        if ("x86_64".equals(abi)) return 4000;
        return 0;
    }

    public static void require(boolean value, String message) {
        if (!value) throw new IllegalArgumentException(message);
    }

    private UpdateValidation() {}
}
