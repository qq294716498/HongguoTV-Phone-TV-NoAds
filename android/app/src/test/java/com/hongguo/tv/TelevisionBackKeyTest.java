package com.hongguo.tv;

public final class TelevisionBackKeyTest {
    private static int checks;

    private static void expect(boolean actual, boolean expected) {
        checks++;
        if (actual != expected) throw new AssertionError("back key assertion " + checks);
    }

    public static void main(String[] args) {
        TelevisionBackKey key = new TelevisionBackKey();
        for (int code : new int[]{4, 111}) {
            expect(key.shouldForward(code, 1, 0, false), false);
            expect(key.shouldForward(code, 0, 0, false), false);
            expect(key.shouldForward(code, 0, 1, false), false);
            expect(key.shouldForward(code, 0, 2, false), false);
            expect(key.shouldForward(code, 1, 0, false), true);
            expect(key.shouldForward(code, 1, 0, false), false);
            expect(key.shouldForward(code, 0, 0, false), false);
            expect(key.shouldForward(code, 1, 0, true), false);
            expect(key.shouldForward(code, 0, 0, false), false);
            key.reset();
            expect(key.shouldForward(code, 1, 0, false), false);
            expect(key.shouldForward(code, 0, 0, false), false);
            expect(key.shouldForward(code + 1, 1, 0, false), false);
            expect(key.shouldForward(code, 0, 0, false), false);
            expect(key.shouldForward(code, 1, 0, false), true);
        }
        System.out.println("Television back key: " + checks + " assertions passed");
    }
}
