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
        assertTrue(
                premium.getEnterpriseFeatures().getPersistentMetrics().isEnabled(),
                "persistent metrics on");
        assertEquals(
                30,
                premium.getEnterpriseFeatures().getPersistentMetrics().getRetentionDays(),
                "metrics retention defaulted");
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
        // Upstream moved ssoAutoLogin from premium.proFeatures to security (#8137).
        assertFalse(props.getSecurity().isSsoAutoLogin(), "sso auto-login left off");
        assertFalse(premium.getProFeatures().isDatabase(), "custom database left off");
        assertFalse(premium.getProFeatures().getGoogleDrive().isEnabled(), "google drive left off");
    }

    @Test
    void leavesPdfMetadataAndAuditToSettings() {
        ApplicationProperties props = new ApplicationProperties();
        props.getPremium().getEnterpriseFeatures().getAudit().setEnabled(false);

        new PremiumFeatureUnlock(props).enableAllPremiumFeatures();

        Premium premium = props.getPremium();
        assertFalse(
                premium.getProFeatures().getCustomMetadata().isAutoUpdateMetadata(),
                "PDF Author is not overwritten unless settings.yml turns it on");
        assertFalse(
                premium.getEnterpriseFeatures().getAudit().isEnabled(),
                "audit follows settings.yml");

        props.getPremium().getProFeatures().getCustomMetadata().setAutoUpdateMetadata(true);
        props.getPremium().getEnterpriseFeatures().getAudit().setEnabled(true);
        new PremiumFeatureUnlock(props).enableAllPremiumFeatures();
        assertTrue(
                premium.getProFeatures().getCustomMetadata().isAutoUpdateMetadata(),
                "explicit metadata setting kept");
        assertTrue(premium.getEnterpriseFeatures().getAudit().isEnabled(), "explicit audit kept");
    }
}
