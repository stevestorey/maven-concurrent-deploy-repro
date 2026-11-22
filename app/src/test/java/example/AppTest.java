package example;

import static org.junit.jupiter.api.Assertions.fail;

import org.junit.jupiter.api.Test;

class AppTest {
    /** Fails after a delay, long enough for the package and deploy steps to run first if nothing orders them after the tests. */
    @Test
    void failsAfterAWhile() throws InterruptedException {
        Thread.sleep(5000);
        fail("deliberate test failure: nothing from this build should be deployed");
    }
}
