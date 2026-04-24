import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:novaapp/core/theme/nova_colors.dart';

class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({super.key});

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  LatLng? _currentLatLng;
  final MapController _mapController = MapController();
  bool _loading = true;

  // Nearby places (mocked for professional look)
  final List<Map<String, String>> _nearbyPlaces = [];

  @override
  void initState() {
    super.initState();
    _getCurrentLocation();
  }

  Future<void> _getCurrentLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition();
      setState(() {
        _currentLatLng = LatLng(position.latitude, position.longitude);
        _loading = false;
        _nearbyPlaces.addAll([
          {'name': 'Tu ubicación actual', 'address': 'Margen de precisión: ${position.accuracy.toStringAsFixed(0)} metros', 'type': 'current'},
          {'name': 'Villavicencio, Meta', 'address': 'Cl. 11 Sur, Villavicencio, Meta, Colombia', 'type': 'place'},
          {'name': 'Centro Comercial Cercano', 'address': 'Calle 10 Sur, Villavicencio, 500003, CO', 'type': 'place'},
          {'name': 'Parque Municipal', 'address': 'Carrera 13 Este, Villavicencio, CO', 'type': 'place'},
          {'name': 'Estación de Servicio', 'address': 'Calle 12 Sur #11-45, Villavicencio, CO', 'type': 'place'},
        ]);
      });
      _mapController.move(_currentLatLng!, 16.0);
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: Column(
        children: [
          // AppBar
          Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 8,
              left: 4, right: 8, bottom: 12,
            ),
            color: const Color(0xFF1C1C1E),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
                const Expanded(
                  child: Text(
                    'Enviar ubicación',
                    style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.search, color: Colors.white),
                  onPressed: () {},
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, color: Colors.white),
                  onPressed: _getCurrentLocation,
                ),
              ],
            ),
          ),

          // Map Section (top half)
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.38,
            child: Stack(
              children: [
                if (_loading)
                  const Center(child: CircularProgressIndicator(color: NovaColors.primary))
                else if (_currentLatLng != null)
                  FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _currentLatLng!,
                      initialZoom: 16.0,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}@2x.png',
                        subdomains: const ['a', 'b', 'c', 'd'],
                        userAgentPackageName: 'com.dybrocorp.novaapp',
                      ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _currentLatLng!,
                            width: 60,
                            height: 60,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.blue.withValues(alpha: 0.15),
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Container(
                                  width: 18,
                                  height: 18,
                                  decoration: BoxDecoration(
                                    color: Colors.blue,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 3),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),

                // My Location Button
                Positioned(
                  top: 12,
                  right: 12,
                  child: GestureDetector(
                    onTap: _getCurrentLocation,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2C2C2E),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 8)],
                      ),
                      child: const Icon(Icons.my_location, color: Colors.white70, size: 22),
                    ),
                  ),
                ),

                // Expand Map Button
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C2C2E),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 8)],
                    ),
                    child: const Icon(Icons.fullscreen, color: Colors.white70, size: 22),
                  ),
                ),
              ],
            ),
          ),

          // Bottom List Section
          Expanded(
            child: Container(
              color: const Color(0xFF0F0F0F),
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  // Real-time Location Option
                  _buildOptionTile(
                    icon: Icons.location_searching,
                    iconColor: NovaColors.primary,
                    title: 'Ubicación en tiempo real',
                    onTap: () {},
                  ),
                  const Divider(color: Color(0xFF2C2C2E), height: 1, indent: 72),

                  // Section Header
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      'Lugares cercanos',
                      style: TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),

                  // Nearby Places
                  ..._nearbyPlaces.map((place) => _buildPlaceTile(place)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOptionTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.15),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
      title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16)),
      onTap: onTap,
    );
  }

  Widget _buildPlaceTile(Map<String, String> place) {
    final isCurrent = place['type'] == 'current';
    return ListTile(
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: isCurrent ? Colors.green.withValues(alpha: 0.15) : const Color(0xFF2C2C2E),
          shape: BoxShape.circle,
        ),
        child: Icon(
          isCurrent ? Icons.my_location : Icons.location_on_outlined,
          color: isCurrent ? Colors.green : Colors.grey,
          size: 22,
        ),
      ),
      title: Text(
        place['name']!,
        style: TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: Text(
        place['address']!,
        style: const TextStyle(color: Colors.grey, fontSize: 13),
      ),
      onTap: () {
        if (_currentLatLng != null) {
          Navigator.pop(context, _currentLatLng);
        }
      },
    );
  }
}
