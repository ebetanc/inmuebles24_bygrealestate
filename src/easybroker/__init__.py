"""EasyBroker Buzón automation.

The EasyBroker public API exposes neither contact_request status changes nor
timeline notes (confirmed against dev.easybroker.com/llms.txt: contact_requests
is GET/POST only; there is no notes endpoint). The two operations the team needs
on every claimed EB lead — set the request to "Atendida" and add a note naming
the assigned agent — are only reachable through the Buzón UI.

This package drives that UI with Playwright (real Chrome via CDP, persistent
profile), mirroring the Inmuebles24 scraper's browser lifecycle but with its own
profile and CDP port so the two can run side by side on the Pi.
"""
