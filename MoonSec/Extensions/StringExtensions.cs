using System;

namespace IronBrew2.Extensions
{
	public static class StringExtensions {
		/// <summary>
		/// takes a substring between two anchor strings (or the end of the string if that anchor is null)
		/// </summary>
		/// <param name="this">a string</param>
		/// <param name="from">an optional string to search after</param>
		/// <param name="until">an optional string to search before</param>
		/// <param name="comparison">an optional comparison for the search</param>
		/// <returns>a substring based on the search</returns>
		public static string Substring(this string @this, string from = null, string until = null, StringComparison comparison = StringComparison.InvariantCulture)
		{
			var fromLength = (from ?? string.Empty).Length;
			var startIndex = !string.IsNullOrEmpty(from) 
				                 ? @this.IndexOf(from, comparison) + fromLength
				                 : 0;

			if (startIndex < fromLength)
				return null;

			var endIndex = !string.IsNullOrEmpty(until) 
				               ? @this.IndexOf(until, startIndex, comparison) 
				               : @this.Length;

			if (endIndex < 0) 
				return null;

			var subString = @this.Substring(startIndex, endIndex - startIndex);
			return subString;
		}
	}
}