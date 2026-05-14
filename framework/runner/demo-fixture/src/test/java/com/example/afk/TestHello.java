package com.example.afk;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class TestHello {

    @Test
    void greetReturnsHi() {
        assertEquals("hi", new Hello().greet());
    }
}
