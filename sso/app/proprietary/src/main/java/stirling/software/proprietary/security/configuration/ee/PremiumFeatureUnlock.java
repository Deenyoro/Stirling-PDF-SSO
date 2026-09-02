package stirling.software.proprietary.security.configuration.ee;

import org.springframework.stereotype.Component;

import jakarta.annotation.PostConstruct;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

import stirling.software.common.model.ApplicationProperties;
import stirling.software.common.model.ApplicationProperties.Premium;

/**
 * Unlocks the premium/enterprise feature set without a paid license.
 *
 * <p>This build runs as the Enterprise tier unconditionally (see {@link KeygenLicenseVerifier} and
 * {@link LicenseKeyChecker}, which bypass key/keygen.sh verification). This startup migration flips
 * the master premium switch on and enables every <em>self-contained</em> premium feature so they
 * are active out of the box.
 *
 * <p>Feature toggles that require extra configuration to function are intentionally left untouched
 * so a default deployment still boots cleanly and the login page keeps working. Enable them in
 * settings once their configuration is provided:
 *
 * <ul>
 *   <li>{@code premium.proFeatures.googleDrive} — needs a Google API client id / api key
 *   <li>{@code premium.proFeatures.database} — needs an external datasource connection
 *   <li>{@code premium.proFeatures.ssoAutoLogin} — redirects past the login page; only useful once
 *       an SSO provider is configured
 * </ul>
 *
 * <p>{@link LicenseKeyChecker} declares {@code @DependsOn("premiumFeatureUnlock")} so the master
 * switch is already on before the license is first evaluated at startup.
 */
@Slf4j
@Component
@RequiredArgsConstructor
public class PremiumFeatureUnlock {

    private final ApplicationProperties applicationProperties;

    @PostConstruct
    public void enableAllPremiumFeatures() {
        Premium premium = applicationProperties.getPremium();

        // Master switch — also gates the SAML2 SSO option on the login page.
        premium.setEnabled(true);

        var enterprise = premium.getEnterpriseFeatures();

        // Audit logging (also requires the Enterprise tier, which this build grants).
        enterprise.getAudit().setEnabled(true);

        // Persistent metrics.
        enterprise.getPersistentMetrics().setEnabled(true);
        if (enterprise.getPersistentMetrics().getRetentionDays() <= 0) {
            enterprise.getPersistentMetrics().setRetentionDays(30);
        }

        // Database backup/import notifications (only delivered once mail is configured).
        var notifications = enterprise.getDatabaseNotifications();
        notifications.getBackups().setSuccessful(true);
        notifications.getBackups().setFailed(true);
        notifications.getImports().setSuccessful(true);
        notifications.getImports().setFailed(true);

        // Automatic PDF metadata stamping.
        premium.getProFeatures().getCustomMetadata().setAutoUpdateMetadata(true);

        log.info(
                "Premium/Enterprise features unlocked — running as ENTERPRISE tier with no license"
                        + " key required.");
    }
}
