package com.hongguo.tv;

import java.util.Set;

public final class UpdateValidationTest {
    private static int checks;
    private static final Set<String> SIGNER = Set.of(UpdateValidation.CERTIFICATE);

    private static void assertTrue(boolean value) {
        checks++;
        if (!value) throw new AssertionError("assertion " + checks);
    }

    private static void reject(Runnable action) {
        try { action.run(); } catch (IllegalArgumentException expected) { checks++; return; }
        throw new AssertionError("Expected rejection");
    }

    public static void main(String[] args) {
        UpdateValidation.verifyVersionName("0.1.12", "0.1.12");
        reject(() -> UpdateValidation.verifyVersionName("0.1.12", "0.1.11"));
        reject(() -> UpdateValidation.verifyVersionName("0.1.12", null));
        reject(() -> UpdateValidation.verifyVersionName("bad", "bad"));
        String hash = "a".repeat(64);
        UpdateValidation.verifyBytes(4, 4, hash, hash);
        reject(() -> UpdateValidation.verifyBytes(4, 3, hash, hash));
        reject(() -> UpdateValidation.verifyBytes(4, 5, hash, hash));
        reject(() -> UpdateValidation.verifyBytes(0, 0, hash, hash));
        reject(() -> UpdateValidation.verifyBytes(UpdateValidation.MAXIMUM_BYTES + 1, UpdateValidation.MAXIMUM_BYTES + 1, hash, hash));
        reject(() -> UpdateValidation.verifyBytes(4, 4, hash, "b".repeat(64)));
        reject(() -> UpdateValidation.verifyBytes(4, 4, "bad", "bad"));
        for (String abi : new String[]{"armeabi-v7a", "arm64-v8a", "x86_64"}) {
            long base = UpdateValidation.offset(abi);
            UpdateValidation.verifyIdentity(UpdateValidation.PACKAGE, UpdateValidation.PACKAGE, SIGNER, SIGNER,
                    base + 27, base + 28, base + 28, abi, Set.of(abi), abi);
            reject(() -> UpdateValidation.verifyIdentity("com.hongguo.tv.debug", UpdateValidation.PACKAGE, SIGNER, SIGNER,
                    base + 27, base + 28, base + 28, abi, Set.of(abi), abi));
            reject(() -> UpdateValidation.verifyIdentity(UpdateValidation.PACKAGE, "other.package", SIGNER, SIGNER,
                    base + 27, base + 28, base + 28, abi, Set.of(abi), abi));
            reject(() -> UpdateValidation.verifyIdentity(UpdateValidation.PACKAGE, UpdateValidation.PACKAGE, Set.of("fake"), Set.of("fake"),
                    base + 27, base + 28, base + 28, abi, Set.of(abi), abi));
            reject(() -> UpdateValidation.verifyIdentity(UpdateValidation.PACKAGE, UpdateValidation.PACKAGE, SIGNER, Set.of("fake"),
                    base + 27, base + 28, base + 28, abi, Set.of(abi), abi));
            reject(() -> UpdateValidation.verifyIdentity(UpdateValidation.PACKAGE, UpdateValidation.PACKAGE, SIGNER, Set.of(UpdateValidation.CERTIFICATE, "extra"),
                    base + 27, base + 28, base + 28, abi, Set.of(abi), abi));
            for (long code : new long[]{base + 26, base + 27, base + 29, base + 1000}) {
                reject(() -> UpdateValidation.verifyIdentity(UpdateValidation.PACKAGE, UpdateValidation.PACKAGE, SIGNER, SIGNER,
                        base + 27, code, base + 28, abi, Set.of(abi), abi));
            }
            reject(() -> UpdateValidation.verifyIdentity(UpdateValidation.PACKAGE, UpdateValidation.PACKAGE, SIGNER, SIGNER,
                    base + 27, base + 28, base + 28, abi, Set.of("wrong"), abi));
            reject(() -> UpdateValidation.verifyIdentity(UpdateValidation.PACKAGE, UpdateValidation.PACKAGE, SIGNER, SIGNER,
                    base + 27, base + 28, base + 28, abi, Set.of(abi, "wrong"), abi));
            reject(() -> UpdateValidation.verifyIdentity(UpdateValidation.PACKAGE, UpdateValidation.PACKAGE, SIGNER, SIGNER,
                    base + 27, base + 28, base + 28, abi, Set.of(abi), "wrong"));
        }
        UpdateInstallSession session = new UpdateInstallSession();
        session.begin(4821);
        session.pause();
        assertTrue(session.resume() == 0);
        assertTrue(!session.canReturn(4821));
        assertTrue(session.launch(4821));
        session.pause();
        assertTrue(session.resume() == 4821);
        assertTrue(session.canReturn(4821));
        assertTrue(session.complete(4821));
        session.begin(4822);
        session.launch(4822);
        session.pause();
        session.resume();
        assertTrue(!session.canReturn(4821));
        assertTrue(!session.matches(4821));
        assertTrue(!session.complete(4821));
        assertTrue(session.canReturn(4822));
        session.pause();
        assertTrue(!session.canReturn(4822));
        assertTrue(session.matches(4822));
        System.out.println("Updater native policy/lifecycle assertions passed: " + checks);
    }
}
