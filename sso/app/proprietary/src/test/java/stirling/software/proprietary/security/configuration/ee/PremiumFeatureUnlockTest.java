package stirling.software.proprietary.security.configuration.ee;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

import stirling.software.common.model.ApplicationProperties;
import stirling.software.common.model.ApplicationProperties.Premium;

class PremiumFeatureUnlockTest {

    @Test
    void enablesPremiumAndSafeFeatures() {
        ApplicationProperties props = new ApplicationProperties();
        props.getPremium().setEnabled(false);

        new PremiumFeatureUnlock(props).enableAllPremiumFeatures();

        Premium premium = props.getPremium();
        assertTrue(premium.isEnabled(), "master premium switch on");
        assertTrue(premium.getEnterpriseFeatures().getAudit().isEnabled(), "audit on");
        assertTrue(
                premium.getEnterpriseFeatures().getPersistentMetrics().isEnabled(),
                "persistent metrics on");
        assertEquals(
                30,
                premium.getEnterpriseFeatures().getPersistentMetrics().getRetentionDays(),
                "metrics retention defaulted");
        assertTrue(
                premium.getProFeatures().getCustomMetadata().isAutoUpdateMetadata(),
                "custom metadata auto-update on");
        assertTrue(
                premium.getEnterpriseFeatures()
                        .getDatabaseNotifications()
                        .getBackups()
                        .isSuccessful(),
                "db backup notifications on");
    }

    @Test
    void leavesConfigDependentFeaturesOff() {
        ApplicationProperties props = new ApplicationProperties();

        new PremiumFeatureUnlock(props).enableAllPremiumFeatures();

        Premium premium = props.getPremium();
        assertFalse(premium.getProFeatures().isSsoAutoLogin(), "sso auto-login left off");
        assertFalse(premium.getProFeatures().isDatabase(), "custom database left off");
        assertFalse(
                premium.getProFeatures().getGoogleDrive().isEnabled(), "google drive left off");
    }
}
