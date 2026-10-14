package com.resonolabs.feature.settings;

import org.junit.Test;

import java.util.List;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

public final class SettingsListLayoutTest {
    private static final float EPS = 0.001f;
    private static final int ROWS = 9;

    @Test public void themeIsAHighRowAndAboutStaysLast() {
        assertEquals(10, SettingsPanelView.ROWS.size());
        assertEquals(List.of("Wi-Fi", "Bluetooth", "Theme"), SettingsPanelView.ROWS.subList(0, 3));
        assertEquals("Side button follows Sound", SettingsPanelView.ROWS.indexOf("Sound") + 1,
                SettingsPanelView.ROWS.indexOf(SettingsPanelView.SIDE_BUTTON));
        assertEquals("About", SettingsPanelView.ROWS.get(SettingsPanelView.ROWS.size() - 1));
        // Theme is fully visible before any scrolling.
        int theme = SettingsPanelView.ROWS.indexOf(SettingsPanelView.THEME);
        assertTrue(SettingsListLayout.rowTop(theme, 0f) + SettingsListLayout.ROW_HEIGHT <= SettingsListLayout.VIEW_BOTTOM);
    }

    @Test public void eightRowsFitButNineScrollJustEnoughToShowAbout() {
        assertEquals(0f, SettingsListLayout.maxScroll(8), EPS);
        assertEquals(0f, SettingsListLayout.maxScroll(0), EPS);
        float max = SettingsListLayout.maxScroll(ROWS);
        assertEquals(88f + 8 * 66f + 58f + 16f - 640f, max, EPS);
        float aboutBottom = SettingsListLayout.rowTop(ROWS - 1, max) + SettingsListLayout.ROW_HEIGHT;
        assertTrue(aboutBottom <= SettingsListLayout.VIEW_BOTTOM);
        assertEquals(SettingsListLayout.VIEW_BOTTOM - SettingsListLayout.BOTTOM_PAD, aboutBottom, EPS);
    }

    @Test public void scrollIsClampedWithoutOverscroll() {
        float max = SettingsListLayout.maxScroll(ROWS);
        assertEquals(0f, SettingsListLayout.clamp(-40f, ROWS), EPS);
        assertEquals(max, SettingsListLayout.clamp(max + 500f, ROWS), EPS);
        assertEquals(20f, SettingsListLayout.clamp(20f, ROWS), EPS);
        assertEquals(0f, SettingsListLayout.clamp(Float.NaN, ROWS), EPS);
        assertEquals(0f, SettingsListLayout.clamp(30f, 8), EPS);   // nothing to scroll
    }

    @Test public void headerBandAndGapsNeverHitARow() {
        for (float scroll : new float[]{0f, 25f, SettingsListLayout.maxScroll(ROWS)}) {
            assertEquals(-1, SettingsListLayout.rowAt(0f, scroll, ROWS));
            assertEquals(-1, SettingsListLayout.rowAt(56f, scroll, ROWS));    // title
            assertEquals(-1, SettingsListLayout.rowAt(77.9f, scroll, ROWS));  // just above the list
            assertEquals(-1, SettingsListLayout.rowAt(Float.NaN, scroll, ROWS));
            assertEquals(-1, SettingsListLayout.rowAt(641f, scroll, ROWS));
        }
        // At the top, the strip between the header line and the first row is empty.
        assertEquals(-1, SettingsListLayout.rowAt(82f, 0f, ROWS));
        // The 8 px gap between Wi-Fi and Bluetooth.
        assertEquals(-1, SettingsListLayout.rowAt(88f + 60f, 0f, ROWS));
    }

    @Test public void rowsAreHitThroughTheScrollOffset() {
        assertEquals(0, SettingsListLayout.rowAt(88f, 0f, ROWS));
        assertEquals(0, SettingsListLayout.rowAt(146f, 0f, ROWS));
        assertEquals(1, SettingsListLayout.rowAt(154f, 0f, ROWS));
        assertEquals(2, SettingsListLayout.rowAt(88f + 2 * 66f + 29f, 0f, ROWS));
        float max = SettingsListLayout.maxScroll(ROWS);
        // Scrolled to the end, About sits where Display used to be and below it.
        float aboutTop = SettingsListLayout.rowTop(ROWS - 1, max);
        assertEquals(ROWS - 1, SettingsListLayout.rowAt(aboutTop + 29f, max, ROWS));
        assertEquals(ROWS - 2, SettingsListLayout.rowAt(aboutTop - 66f + 29f, max, ROWS));
        // The sliver of Wi-Fi still visible under the header is its row, not Bluetooth.
        assertEquals(0, SettingsListLayout.rowAt(80f, max, ROWS));
        // Below the last row's end there is nothing.
        assertEquals(-1, SettingsListLayout.rowAt(639f, max, ROWS));
        // At the top About is cut off by the screen edge but its visible part still works.
        assertEquals(ROWS - 1, SettingsListLayout.rowAt(630f, 0f, ROWS));
    }

    @Test public void revealKeepsTheFocusedRowOnScreenAndMovesAsLittleAsPossible() {
        float max = SettingsListLayout.maxScroll(ROWS);
        assertEquals(0f, SettingsListLayout.reveal(0, max, ROWS), EPS);
        assertEquals(max, SettingsListLayout.reveal(ROWS - 1, 0f, ROWS), EPS);
        // Rows already in view keep the scroll where it is.
        assertEquals(0f, SettingsListLayout.reveal(3, 0f, ROWS), EPS);
        assertEquals(max, SettingsListLayout.reveal(3, max, ROWS), EPS);
        assertEquals(20f, SettingsListLayout.reveal(4, 20f, ROWS), EPS);
        // Display, second to last, fits without scrolling.
        float display = SettingsListLayout.reveal(ROWS - 2, 0f, ROWS);
        assertTrue(SettingsListLayout.rowTop(ROWS - 2, display) + SettingsListLayout.ROW_HEIGHT
                + SettingsListLayout.REVEAL_MARGIN <= SettingsListLayout.VIEW_BOTTOM + EPS);
        // Bluetooth, scrolled to the end, comes back below the header with its margin.
        float bluetooth = SettingsListLayout.reveal(1, max, ROWS);
        assertTrue(SettingsListLayout.rowTop(1, bluetooth) - SettingsListLayout.REVEAL_MARGIN
                >= SettingsListLayout.VIEW_TOP - EPS);
        // Every row is fully visible after reveal, from any start.
        for (int row = 0; row < ROWS; row++) {
            for (float start : new float[]{0f, max / 2f, max, -10f, max + 10f}) {
                float s = SettingsListLayout.reveal(row, start, ROWS);
                assertTrue(s >= 0f && s <= max);
                assertTrue(SettingsListLayout.rowTop(row, s) >= SettingsListLayout.VIEW_TOP - EPS);
                assertTrue(SettingsListLayout.rowTop(row, s) + SettingsListLayout.ROW_HEIGHT
                        <= SettingsListLayout.VIEW_BOTTOM + EPS);
            }
        }
    }
}
