# Takagi Roadmap

## Takagi 1.0 – Core CoAP Framework (Current Phase)
**Goal:** A functional CoAP server & client, usable for IoT and edge computing.

**Internal definition:** Sinatra for CoAP

- [x] **Takagi Server** → Routing, dynamic paths (`/devices/:id`), basic message parsing.
- [x] **Takagi Client** → Enables communication with the Takagi Server.
- [x] **Basic support for URL ID parameters & payloads.**
- [x] **Logging and debugging for easier development.**
- [ ] **Sequel support for seamless storing data from CoAP**
- [x] **Better error handling & stability improvements.** — lib/takagi/errors.rb
- [ ] **Extended routing DSL (e.g., wildcards).**
- [x] **Tests and RFC compatibility checks.** — spec/rfc/
- [x] **Push Notifications (Observe)** — lib/takagi/observe_registry.rb 

---

## Takagi-Device (Spiegel) – IoT Device Management Module (Post-1.0)
**Goal:** A full-fledged device management system over CoAP.

**Internal definition:** Know everything about your devices like Spike Spiegel about his enemies

- [ ] **Device Registration** → like `/register` endpoint.
- [ ] **Real-time Monitoring** → like `/status` endpoint.
- [ ] **Device Authentication** → Basic token-based security.
- [ ] **Notify clients about state changes trough Observer**
- [ ] **Define a standardized API for devices.**
- [ ] **Integrate with more databases (InfluxDB?).**
- [ ] **Scalability & performance testing.**

---

## Takagi-Sinatra – Web Dashboard
**Goal:** Web integration visualization & admin panel for IoT device management.

**Internal definition:** Because Takagi and Sinatra would be great duo!

- [ ] **Show online/offline devices.**
- [ ] **Visualize metrics (battery, signal strength, temperature, etc.).**
- [ ] **CRUD operations for managing devices.**
- [ ] **Charts & real-time data streaming.**
- [ ] **Authentication & user access control.**

---

## Takagi-Zephyr – Embedded Integration with ZephyrOS
**Goal:** Allow communicate with Takagi on low-power IoT devices with Spiegel management.

**Internal definition:** Because software is not everything.

- [ ] **Develop Spiegel-able library for ZephyrOS**
- [ ] **Minimalist footprint for embedded systems.**
- [ ] **Test edge computing use-cases.**
