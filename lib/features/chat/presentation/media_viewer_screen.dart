import 'dart:io';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:share_plus/share_plus.dart';

class MediaViewerScreen extends StatelessWidget {
  final String mediaUrl;
  final bool isVideo;

  const MediaViewerScreen({
    super.key,
    required this.mediaUrl,
    this.isVideo = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black45,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            onPressed: () => Share.shareXFiles([XFile(mediaUrl)]),
          ),
          IconButton(
            icon: const Icon(Icons.download_outlined),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Guardado en la galería')),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: Hero(
          tag: mediaUrl,
          child: PhotoView(
            imageProvider: FileImage(File(mediaUrl)),
            minScale: PhotoViewComputedScale.contained * 0.8,
            maxScale: PhotoViewComputedScale.covered * 2,
            backgroundDecoration: const BoxDecoration(color: Colors.black),
          ),
        ),
      ),
    );
  }
}
