/** Article episodes carry the source page URL. The snapshot rewrites audio_url
 * to the published artifact, so article_url is the discriminator there; the
 * article: audio_url prefix covers rows served through legacy routes. */
export function isArticle(item: { article_url?: string | null; audio_url: string }): boolean {
  return !!item.article_url || item.audio_url.startsWith("article:");
}
