package com.hongguo.tv;

public final class TelevisionBackKey {
    private int pressedKey = -1;

    public boolean shouldForward(int key, int action, int repeatCount, boolean canceled) {
        if (canceled) {
            reset();
            return false;
        }
        if (action == 0 && repeatCount == 0) {
            pressedKey = key;
            return false;
        }
        if (action != 1) return false;
        boolean forward = pressedKey == key;
        reset();
        return forward;
    }

    public void reset() {
        pressedKey = -1;
    }
}
