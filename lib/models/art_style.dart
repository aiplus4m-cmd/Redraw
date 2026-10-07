/// Art styles offered when repainting a picture.
enum ArtStyle {
  original('Giữ phong cách gốc', ''),
  digital('Tranh kỹ thuật số', 'a polished, high-quality digital painting'),
  watercolor('Màu nước', 'a soft, luminous watercolor painting'),
  oil('Sơn dầu', 'a rich oil painting on canvas with visible brushwork'),
  cartoon(
    'Hoạt hình',
    'a clean cartoon illustration with bold outlines and bright colors',
  ),
  anime('Anime', 'a detailed anime / manga style illustration'),
  storybook('Sách thiếu nhi', "a warm children's picture-book illustration"),
  pencil(
    'Chì phác thảo',
    'a detailed graphite pencil drawing with careful shading',
  ),
  flat('Phẳng (flat)', 'a modern flat vector illustration'),
  render3d('3D', 'a 3D rendered illustration with soft studio lighting'),
  realistic('Chân thực', 'a photorealistic image');

  const ArtStyle(this.label, this.prompt);

  final String label;

  /// English description used in prompts ('' = keep the original style).
  final String prompt;

  static ArtStyle parse(String? name) => ArtStyle.values.firstWhere(
    (s) => s.name == name,
    orElse: () => ArtStyle.original,
  );
}
